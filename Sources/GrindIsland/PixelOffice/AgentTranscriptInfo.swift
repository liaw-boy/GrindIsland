import Foundation

/// What the card shows beyond the session file: the AI-written title, the tool in use and the token count, read from
/// the session's transcript. The format is not a public promise, so anything unparseable is simply "no info".
struct AgentExtraInfo: Equatable, Sendable {
    var title: String?
    var currentTool: String?
    var tokens: Int = 0
}

/// Reads transcripts incrementally (only the bytes appended since the last scan). Used from one serial queue.
final class AgentTranscriptReader: @unchecked Sendable {
    private struct Cursor {
        var offset: UInt64 = 0
        var info = AgentExtraInfo()
        var perMessage: [String: Int] = [:]   // streamed lines repeat a message id; keep the last usage of each
        var carry = Data()
    }
    private var cursors: [String: Cursor] = [:]

    /// `sessionId` must be a UUID; the path is built here from it and `cwd`, never taken from the file.
    func info(sessionId: String, cwd: String) -> AgentExtraInfo? {
        guard UUID(uuidString: sessionId) != nil, !cwd.isEmpty else { return nil }
        let folder = cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let path = NSHomeDirectory() + "/.claude/projects/" + folder + "/" + sessionId + ".jsonl"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var c = cursors[sessionId] ?? Cursor()
        if size < c.offset { c = Cursor() }                       // file was replaced
        if size > c.offset {
            try? handle.seek(toOffset: c.offset)
            // Cap one read at 4MB: a huge backlog is read over a few scans.
            let chunk = (try? handle.read(upToCount: 4_000_000)) ?? Data()
            c.offset += UInt64(chunk.count)
            var data = c.carry + chunk
            if let nl = data.lastIndex(of: 0x0A) {
                c.carry = data.subdata(in: data.index(after: nl)..<data.endIndex)
                data = data.subdata(in: data.startIndex..<nl)
                for line in data.split(separator: 0x0A) { parse(Data(line), into: &c) }
            } else { c.carry = data }
        }
        c.info.tokens = c.perMessage.values.reduce(0, +)
        cursors[sessionId] = c
        return c.info
    }

    func forget(except live: Set<String>) { cursors = cursors.filter { live.contains($0.key) } }

    private func parse(_ line: Data, into c: inout Cursor) {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = d["type"] as? String else { return }
        if type == "ai-title" {
            if let t = d["aiTitle"] as? String, !t.isEmpty { c.info.title = t }
        } else if type == "assistant", let m = d["message"] as? [String: Any] {
            if let id = m["id"] as? String, let u = m["usage"] as? [String: Any] {
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                c.perMessage[id] = n("input_tokens") + n("cache_creation_input_tokens") + n("output_tokens")
            }
            for block in (m["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_use" {
                c.info.currentTool = Self.describe(name: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:])
            }
        }
    }

    /// "Bash · npm test", "Edit · Foo.swift": the tool and the one detail worth showing (never file contents).
    private static func describe(name: String, input: [String: Any]) -> String {
        var detail: String?
        if let p = input["file_path"] as? String { detail = URL(fileURLWithPath: p).lastPathComponent }
        else if let cmd = input["command"] as? String { detail = String(cmd.prefix(28)) }
        else if let q = input["pattern"] as? String ?? input["query"] as? String { detail = String(q.prefix(28)) }
        return detail.map { "\(name) · \($0)" } ?? name
    }
}
