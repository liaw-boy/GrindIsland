import Foundation
import SwiftUI

/// Token use of local Claude Code sessions, read from its own transcripts (~/.claude/projects/**/*.jsonl).
/// Only the usage numbers, the model, the time and the project folder name are read, never the conversation.
/// Files are read incrementally (each remembers how far it was read), only those changed in the last `days`.
final class UsageStats: ObservableObject {
    static let shared = UsageStats()
    static let days = 14

    struct Record: Equatable {
        let id: String              // message id: a reply is logged on several lines with the same usage
        let date: Date
        let model: String
        let project: String
        let input: Int, output: Int, cacheWrite: Int, cacheRead: Int
        var total: Int { input + output + cacheWrite + cacheRead }
    }

    struct Summary: Equatable {
        var todayTokens = 0
        var todayOutput = 0
        var todayReplies = 0
        var perDay: [Int] = []               // total tokens per day, oldest first, `days` long, today last
        var hoursToday: [Int] = Array(repeating: 0, count: 24)   // replies per hour today
        var topProjects: [(name: String, tokens: Int)] = []      // last 7 days
        var topModels: [(name: String, tokens: Int)] = []        // last 7 days
        var streak = 0                       // days in a row with use, up to today

        static func == (a: Summary, b: Summary) -> Bool {
            a.todayTokens == b.todayTokens && a.todayReplies == b.todayReplies && a.perDay == b.perDay
                && a.hoursToday == b.hoursToday && a.streak == b.streak
                && a.topProjects.map(\.name) == b.topProjects.map(\.name) && a.topModels.map(\.name) == b.topModels.map(\.name)
        }
    }

    @Published private(set) var summary = Summary()
    @Published private(set) var loading = false

    private let root: URL
    private let queue = DispatchQueue(label: "grindisland.usage", qos: .utility)
    private var files: [String: (offset: UInt64, records: [Record])] = [:]   // only touched on `queue`
    private var timer: Timer?
    private var watchers = 0

    init(root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    /// While the usage view is open: refresh now and every minute.
    func watch() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.commonModeTimer(interval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        loading = true
        queue.async { [self] in
            let now = Date()
            let cutoff = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(Self.days) * 86400)
            let urls = transcripts(changedSince: cutoff)
            // Forget files that left the window, so the cache does not grow forever.
            let keep = Set(urls.map(\.path))
            files = files.filter { keep.contains($0.key) }
            // One reply can appear in several files (a resumed or forked session copies its history): count it once.
            var all: [Record] = [], seen = Set<String>()
            for url in urls {
                for r in read(url, cutoff: cutoff) where seen.insert(r.id).inserted { all.append(r) }
            }
            let s = Self.summarize(all, now: now, calendar: .current)
            DispatchQueue.main.async { self.summary = s; self.loading = false }
        }
    }

    /// Transcripts (also subagents' in subfolders) modified after `date`. Paths stay under the projects folder.
    private func transcripts(changedSince date: Date) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if v?.isRegularFile == true, (v?.contentModificationDate ?? .distantPast) >= date { out.append(url) }
        }
        return out
    }

    /// Records of one file, reading only what was appended since last time.
    private func read(_ url: URL, cutoff: Date) -> [Record] {
        let key = url.path
        var entry = files[key] ?? (0, [])
        guard let h = try? FileHandle(forReadingFrom: url) else { return entry.records }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < entry.offset { entry = (0, []) }          // rewritten: start over
        guard size > entry.offset else { return entry.records }
        try? h.seek(toOffset: entry.offset)
        var seen = Set(entry.records.map(\.id))
        var carry = Data()
        // 8 MB at a time (transcripts reach hundreds of MB); only whole lines count, a half-written last line is
        // read next time.
        while let piece = autoreleasepool(invoking: { try? h.read(upToCount: 8 << 20) }), !piece.isEmpty {
            var buf = carry + piece
            guard let lastNewline = buf.lastIndex(of: 0x0A) else {
                // A "line" over 64 MB is not a transcript line: skip it rather than holding it all in memory.
                if buf.count > 64 << 20 { entry.offset += UInt64(buf.count); carry = Data() } else { carry = buf }
                continue
            }
            let whole = buf[buf.startIndex...lastNewline]
            // Jump straight to the lines that carry a usage object (memmem over the whole piece, not line by line).
            for line in Self.lines(containing: Self.usageMarker, in: whole) {
                guard let r = Self.record(fromLine: line), !seen.contains(r.id) else { continue }
                seen.insert(r.id)
                entry.records.append(r)
            }
            entry.offset += UInt64(whole.count)
            buf.removeSubrange(buf.startIndex...lastNewline)
            carry = buf
        }
        entry.records.removeAll { $0.date < cutoff }
        files[key] = entry
        return entry.records
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// One assistant reply's usage from a transcript line; nil for anything else. Content is never parsed: the few
    /// fields are found as raw `"key":` bytes (inside a string they would be escaped as `\"key\"`, so they cannot
    /// be mistaken), and only the small usage object goes through the JSON parser. Lines are long (whole replies).
    static func record(fromLine line: Data) -> Record? {
        guard let usageAt = field(line, "\"usage\":{"), field(line, "\"type\":\"assistant\"") != nil,
              let id = string(line, "\"id\":\""), id.hasPrefix("msg"),
              let ts = string(line, "\"timestamp\":\""),
              let date = isoFull.date(from: ts) ?? isoPlain.date(from: ts),
              let obj = object(line, from: usageAt.upperBound - 1),
              let u = try? JSONSerialization.jsonObject(with: obj) as? [String: Any] else { return nil }
        func n(_ k: String) -> Int { max(0, (u[k] as? NSNumber)?.intValue ?? 0) }
        let model = string(line, "\"model\":\"").map { String($0.prefix(60)) } ?? "?"
        guard model != "<synthetic>" else { return nil }
        let project = string(line, "\"cwd\":\"").map { String(URL(fileURLWithPath: $0).lastPathComponent.prefix(60)) } ?? "?"
        return Record(id: String(id.prefix(80)), date: date, model: model, project: project,
                      input: n("input_tokens"), output: n("output_tokens"),
                      cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens"))
    }

    /// The whole lines of `buf` that contain `marker`, each once.
    static func lines(containing marker: Data, in buf: Data) -> [Data] {
        var out: [Data] = []
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, !marker.isEmpty else { return }
            marker.withUnsafeBytes { (m: UnsafeRawBufferPointer) in
                var pos = 0
                while pos < raw.count, let hit = memmem(base + pos, raw.count - pos, m.baseAddress!, m.count) {
                    let at = UnsafeRawPointer(hit) - base
                    var start = at
                    while start > 0, raw[start - 1] != 0x0A { start -= 1 }
                    let endPtr = memchr(base + at, 0x0A, raw.count - at)
                    let end = endPtr.map { UnsafeRawPointer($0) - base } ?? raw.count
                    out.append(Data(bytes: base + start, count: end - start))
                    pos = end + 1
                }
            }
        }
        return out
    }

    /// The first unescaped occurrence of `key` (raw JSON bytes), as offsets into `line`.
    private static func field(_ line: Data, _ key: String) -> Range<Data.Index>? {
        let k = Array(key.utf8)
        return line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Range<Data.Index>? in
            guard let base = raw.baseAddress else { return nil }
            var pos = 0
            while pos < raw.count, let hit = memmem(base + pos, raw.count - pos, k, k.count) {
                let at = UnsafeRawPointer(hit) - base
                if at == 0 || raw[at - 1] != 0x5C {   // not \" (a key written inside a string)
                    return (line.startIndex + at)..<(line.startIndex + at + k.count)
                }
                pos = at + 1
            }
            return nil
        }
    }

    /// The plain string value after `key` (up to the closing quote; values with escapes are not needed here).
    private static func string(_ line: Data, _ key: String) -> String? {
        guard let r = field(line, key), let end = line[r.upperBound...].firstIndex(of: 0x22) else { return nil }
        return String(data: line[r.upperBound..<end], encoding: .utf8)
    }

    /// The `{…}` object starting at `start`, by brace depth (outside strings).
    private static func object(_ line: Data, from start: Data.Index) -> Data? {
        guard start < line.endIndex, line[start] == 0x7B else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < line.endIndex {
            let b = line[i]
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
            } else if b == 0x22 { inString = true }
            else if b == 0x7B { depth += 1 }
            else if b == 0x7D { depth -= 1; if depth == 0 { return line[start...i] } }
            i = line.index(after: i)
            if i - start > 8192 { return nil }   // a usage object is small
        }
        return nil
    }

    static func summarize(_ records: [Record], now: Date, calendar cal: Calendar) -> Summary {
        var s = Summary()
        let today = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        var perDay = Array(repeating: 0, count: days)
        var projects: [String: Int] = [:], models: [String: Int] = [:]
        for r in records {
            let d = cal.startOfDay(for: r.date)
            let back = cal.dateComponents([.day], from: d, to: today).day ?? 99
            if (0..<days).contains(back) { perDay[days - 1 - back] += r.total }
            if d == today {
                s.todayTokens += r.total
                s.todayOutput += r.output
                s.todayReplies += 1
                s.hoursToday[cal.component(.hour, from: r.date)] += 1
            }
            if d >= weekStart {
                projects[r.project, default: 0] += r.total
                models[r.model, default: 0] += r.total
            }
        }
        s.perDay = perDay
        s.topProjects = projects.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) }
        s.topModels = models.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) }
        s.streak = perDay.reversed().prefix { $0 > 0 }.count
        return s
    }

    /// "1.2M", "34K", "980".
    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1e3)
        default: return "\(n)"
        }
    }
}
