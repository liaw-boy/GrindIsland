import Foundation
import AppKit
import QuartzCore
import Combine

public struct LyricLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let text: String
    public let translation: String?

    public init(id: Int, startTime: Double, endTime: Double, text: String, translation: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.translation = translation
    }
}

extension LyricLine {
    /// Rough time a singer needs for this text (CJK ≈ 0.3s per character, Latin ≈ 0.08s).
    static func estimatedSingingTime(for text: String) -> Double {
        var t = 0.0
        for c in text.unicodeScalars {
            if c.value >= 0x2E80 { t += 0.3 }
            else if CharacterSet.letters.contains(c) { t += 0.08 }
            else if c == " " { t += 0.05 }
            else { t += 0.1 }
        }
        return max(t, 1.2)
    }

    /// How long the highlight sweep should take. Normally the whole gap to the next line, but when most of
    /// that gap is instrumental the sweep only takes the estimated singing time and then holds.
    var sweepDuration: Double {
        let gap = max(endTime - startTime, 0.5)
        let sung = Self.estimatedSingingTime(for: text) * 1.25
        return gap > sung * 1.6 ? sung : gap
    }

    /// Long instrumental after this line was sung: at least `minGap` seconds of music before the next line.
    /// True only in the middle of that stretch, so the sung line stays a moment and the next one is back in time.
    func isInterlude(at pos: Double, minGap: Double = 8, margin: Double = 1.5) -> Bool {
        interludeProgress(at: pos, minGap: minGap, margin: margin) != nil
    }

    /// 0...1 through the interlude (Apple Music style: the dots fill in over the break), nil outside it.
    func interludeProgress(at pos: Double, minGap: Double = 8, margin: Double = 1.5) -> Double? {
        let sungEnd = startTime + Self.estimatedSingingTime(for: text) * 1.25
        guard endTime - sungEnd >= minGap else { return nil }
        let from = sungEnd + margin, to = endTime - margin
        guard pos > from, pos < to else { return nil }
        return (pos - from) / (to - from)
    }
}

extension LyricDoc {
    /// A copy whose translations went through `transform`.
    func convertingTranslations(_ transform: (String) -> String) -> LyricDoc {
        LyricDoc(lines: lines.map {
            LyricLine(id: $0.id, startTime: $0.startTime, endTime: $0.endTime, text: $0.text,
                      translation: $0.translation.map(transform))
        })
    }
}

public struct LyricDoc: Equatable, Sendable {
    public let lines: [LyricLine]

    public init(lines: [LyricLine]) {
        self.lines = lines
    }
}

public final class LyricService: ObservableObject, @unchecked Sendable {
    public static let shared = LyricService()

    @Published public var currentLyrics: LyricDoc?
    @Published public var currentLineIndex: Int = 0
    /// The collapsed island's own copy: long lines split to fit its width. The expanded view keeps `currentLyrics`.
    @Published public var compactLyrics: LyricDoc?
    @Published public var compactLineIndex: Int = 0
    @Published public var compactLineProgress: CGFloat = 0.0
    /// True while the playback position is before the first lyric line (the intro): show only the title.
    @Published public var isIntro: Bool = false
    /// A long instrumental between two lines (the compact row shows breathing dots instead of the old line).
    @Published public var isInterlude: Bool = false
    /// The translations are on-device machine translations (the source had none), not human ones.
    @Published public var translationIsMachine: Bool = false
    /// True from the moment a track change starts a lyric search until it finishes (found or not).
    @Published public var isLoading: Bool = false

    private var payloadMemo: [String: LyricPayload] = [:]
    private var missCache: [String: Date] = [:]
    private var fetchGeneration = 0
    private var activeTitle: String = ""
    private var activeArtist: String = ""
    private var syncTimer: Timer?
    private var syncLink: CADisplayLink?
    private var syncTarget: SyncTarget?

    /// Lyrics exactly as fetched; `currentLyrics` is this after optional line splitting.
    private var rawDoc: LyricDoc?
    private var settingsObserver: AnyCancellable?

    private init() {
        startSyncLoop()
        // Re-split when the font size, island width or the split option changes.
        settingsObserver = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.rebuildLyrics() }
            }
    }

    /// Drops the current lyrics and cancels any in-flight request (Music stopped).
    public func clear() {
        fetchGeneration += 1
        isLoading = false
        isIntro = false
        activeTitle = ""
        activeArtist = ""
        rawDoc = nil
        translationIsMachine = false
        currentLyrics = nil
        compactLyrics = nil
        currentLineIndex = 0
        LyricProgress.shared.expanded = 0
        compactLineIndex = 0
        compactLineProgress = 0
    }

    private func rebuildLyrics() {
        guard let rawSource = rawDoc else { return }
        let settings = AppSettings.shared
        let raw = settings.translationTraditional ? rawSource.convertingTranslations(ChineseConverter.toTraditional) : rawSource
        if raw != currentLyrics { currentLyrics = raw }     // expanded view: lines exactly as sung

        // Collapsed island: long lines are split to fit its width (the expanded view keeps the lines as sung).
        let lyricWidth = NotchGeometry.shared.compactLyricWidth
        let sideBySide = settings.showTranslation && settings.translationSideBySide
        // Side by side, the original only gets half of the row.
        let usable = sideBySide ? (lyricWidth - 13) / 2 - 8 : lyricWidth - 8
        let compact = LyricSplitter.split(
            raw, maxWidth: usable, fontSize: 13 * CGFloat(settings.lyricFontScale),
            translationFontSize: sideBySide ? 13 * CGFloat(settings.lyricFontScale) : nil)
        if compact != compactLyrics { compactLyrics = compact }
    }

    /// Line index and sweep progress for `pos` within `lines`.
    private static func locate(_ lines: [LyricLine], at pos: Double) -> (index: Int, progress: CGFloat) {
        var found = 0
        for (i, line) in lines.enumerated() {
            if pos >= line.startTime { found = i } else { break }
        }
        let line = lines[found]
        let elapsed = max(pos - line.startTime, 0.0)
        // Finish at 92% of the line's time so the last character is fully lit for a moment before the next line.
        return (found, CGFloat(min(max(elapsed / (line.sweepDuration * 0.92), 0.0), 1.0)))
    }

    private func startSyncLoop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Tick with the display (a 30Hz timer beats against a 60/120Hz screen, so the sweep advanced unevenly).
            if let screen = NSScreen.main {
                let target = SyncTarget { [weak self] in self?.updateSync() }
                let link = screen.displayLink(target: target, selector: #selector(SyncTarget.tick(_:)))
                // Which line is current and how many characters are lit: 15 times a second is plenty (the collapsed
                // sweep reads the live position itself, every frame it draws).
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
                link.add(to: .main, forMode: .common)
                self.syncTarget = target
                self.syncLink = link
            } else {
                self.syncTimer = Timer.commonModeTimer(interval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                    self?.updateSync()
                }
            }
        }
    }

    /// How far through the current interlude the live position is (0 when not in one); read every frame by the dots.
    public func liveInterludeProgress() -> CGFloat {
        guard let lines = compactLyrics?.lines, lines.indices.contains(compactLineIndex) else { return 0 }
        let pos = MusicTracker.shared.livePosition(forLyrics: true)
        return CGFloat(lines[compactLineIndex].interludeProgress(at: pos) ?? 0)
    }

    /// Sweep progress of compact line `index` at the live position (read by the karaoke view on every frame).
    public func liveCompactProgress(forLine index: Int) -> CGFloat {
        guard let lines = compactLyrics?.lines, lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        let pos = MusicTracker.shared.livePosition(forLyrics: true)
        return CGFloat(min(max((pos - line.startTime) / (line.sweepDuration * 0.92), 0.0), 1.0))
    }

    public func updateSync() {
        guard let doc = currentLyrics, !doc.lines.isEmpty else {
            if currentLineIndex != 0 { currentLineIndex = 0 }
            if LyricProgress.shared.expanded != 0 { LyricProgress.shared.expanded = 0 }
            if compactLineIndex != 0 { compactLineIndex = 0 }
            if compactLineProgress != 0 { compactLineProgress = 0 }
            if isIntro { isIntro = false }
            if isInterlude { isInterlude = false }
            return
        }

        let pos = MusicTracker.shared.livePosition(forLyrics: true)

        let expanded = Self.locate(doc.lines, at: pos)
        if expanded.index != currentLineIndex { currentLineIndex = expanded.index }
        // Every frame, so it lives in its own object that only the lyric rows watch: publishing it here redrew the
        // whole island 60 times a second, and clicks on the tab bar got lost between redraws.
        if NotchGeometry.anyExpanded, expanded.progress != LyricProgress.shared.expanded { LyricProgress.shared.expanded = expanded.progress }

        if let compact = compactLyrics, !compact.lines.isEmpty {
            let c = Self.locate(compact.lines, at: pos)
            if c.index != compactLineIndex { compactLineIndex = c.index }
            let interlude = pos >= compact.lines[0].startTime && compact.lines[c.index].isInterlude(at: pos)
            if interlude != isInterlude { isInterlude = interlude }
        }

        let intro = pos < doc.lines[0].startTime
        if intro != isIntro { isIntro = intro }
    }

    public func fetchLyrics(title: String, artist: String, duration: Double) {
        let cleanTitle = cleanQuery(title)
        let cleanArtist = cleanQuery(artist)

        guard cleanTitle != activeTitle || cleanArtist != activeArtist else { return }
        self.activeTitle = cleanTitle
        self.activeArtist = cleanArtist

        // New track: drop the previous song's lyrics right away, and ignore any in-flight request for it.
        fetchGeneration += 1
        let generation = fetchGeneration
        DispatchQueue.main.async { [weak self] in
            self?.isLoading = true
            self?.rawDoc = nil
            self?.translationIsMachine = false
            self?.currentLyrics = nil
            self?.compactLyrics = nil
            self?.currentLineIndex = 0
            LyricProgress.shared.expanded = 0
        }

        // "v1" lets a future change of the stored format invalidate old files.
        let cacheKey = "v1|\(cleanTitle)|\(cleanArtist)|\(Int(duration))"

        // Parse and display a payload (on the main thread), unless another track started in the meantime.
        let show: (LyricPayload?) -> Void = { [weak self] payload in
            DispatchQueue.main.async {
                guard let self = self, self.fetchGeneration == generation else { return }
                self.isLoading = false
                var doc: LyricDoc?
                if let payload = payload {
                    let parsed = Self.parseLRC(lrc: payload.lrc, translationLrc: payload.translation)
                    doc = parsed.lines.isEmpty ? nil : parsed
                }
                self.rawDoc = doc
                self.translationIsMachine = false
                if doc == nil { self.currentLyrics = nil; self.compactLyrics = nil } else { self.rebuildLyrics() }
                // No translation from the source: fill one in on-device, then swap it in if the track is unchanged.
                if let doc = doc, MachineTranslator.sourceLanguage(of: doc) != nil {
                    Task {
                        guard let translated = await MachineTranslator.translate(doc) else { return }
                        await MainActor.run {
                            guard self.fetchGeneration == generation else { return }
                            self.rawDoc = translated
                            self.translationIsMachine = true
                            self.rebuildLyrics()
                        }
                    }
                }
            }
        }

        // 1) memory, 2) a recent miss, 3) disk, 4) the network. Only hits are written to disk; a miss is
        //    remembered for 90 seconds so a missing song does not hit the services again and again.
        if let memo = payloadMemo[cacheKey] { show(memo); return }
        if let missedAt = missCache[cacheKey], Date().timeIntervalSince(missedAt) < 90 { show(nil); return }

        LyricCache.shared.load(key: cacheKey, days: LyricCache.retentionDays) { [weak self] cached in
            guard let self = self, self.fetchGeneration == generation else { return }
            if let cached = cached {
                self.payloadMemo[cacheKey] = cached
                show(cached)
                return
            }
            self.fetchFromNetwork(title: cleanTitle, artist: cleanArtist, duration: duration) { [weak self] payload in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let payload = payload {
                        self.payloadMemo[cacheKey] = payload
                        LyricCache.shared.store(key: cacheKey, payload: payload)
                    } else {
                        self.missCache[cacheKey] = Date()
                    }
                }
                show(payload)
            }
        }
    }

    private func fetchFromNetwork(title cleanTitle: String, artist cleanArtist: String, duration: Double,
                                  completion: @escaping (LyricPayload?) -> Void) {
        let isCJK = hasCJK(cleanTitle) || hasCJK(cleanArtist)

        // Try sources in order until one returns lyrics. CJK songs start with NetEase (it has the original text and
        // translations); the others start with LRCLIB. Every source has a fallback: NetEase is rate limited at times,
        // and LRCLIB lists many songs under a romanized title, so a fuzzy search by duration is tried as well.
        let netEase: LyricSource = { [weak self] done in
            self?.fetchNetEase(title: cleanTitle, artist: cleanArtist, duration: duration, completion: done) ?? done(nil)
        }
        let lrclibExact: LyricSource = { [weak self] done in
            self?.fetchLRCLIB(title: cleanTitle, artist: cleanArtist, duration: duration, requireCJK: isCJK, completion: done) ?? done(nil)
        }
        let lrclibSearch: LyricSource = { [weak self] done in
            self?.searchLRCLIB(title: cleanTitle, artist: cleanArtist, duration: duration, requireCJK: isCJK, completion: done) ?? done(nil)
        }
        runChain(isCJK ? [netEase, lrclibExact, lrclibSearch] : [lrclibExact, lrclibSearch, netEase], completion: completion)
    }

    private typealias LyricSource = (@escaping (LyricPayload?) -> Void) -> Void

    /// Tries each source in turn; a source "succeeds" only if its text parses into at least one lyric line.
    private func runChain(_ sources: [LyricSource], completion: @escaping (LyricPayload?) -> Void) {
        guard let first = sources.first else { completion(nil); return }
        first { [weak self] payload in
            if let payload = payload,
               let self = self,
               !Self.parseLRC(lrc: payload.lrc, translationLrc: payload.translation).lines.isEmpty {
                completion(payload)
            } else {
                self?.runChain(Array(sources.dropFirst()), completion: completion)
            }
        }
    }

    private static func jsonRequest(_ url: URL, post form: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        if let form = form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var comps = URLComponents()
            comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        }
        return request
    }

    /// Picks the search hit that best matches the playing track: duration within a few seconds first, then the
    /// title / artist text; falls back to the first hit.
    private static func bestNetEaseSong(_ songs: [[String: Any]], title: String, artist: String, duration: Double) -> Int? {
        func score(_ song: [String: Any]) -> Double {
            var sc = 0.0
            if let ms = song["duration"] as? Double ?? (song["duration"] as? Int).map(Double.init), duration > 0 {
                let diff = abs(ms / 1000 - duration)
                sc += diff <= 3 ? 10 : (diff <= 8 ? 4 : -4)
            }
            if let name = song["name"] as? String, name.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(name) { sc += 3 }
            let artists = (song["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            if artists.contains(where: { $0.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains($0) }) { sc += 2 }
            return sc
        }
        return songs.max(by: { score($0) < score($1) })?["id"] as? Int
    }

    private func fetchNetEase(title: String, artist: String, duration: Double, completion: @escaping (LyricPayload?) -> Void) {
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        guard let searchURL = URL(string: "https://music.163.com/api/search/get") else { completion(nil); return }
        // POST is not rate limited the way the old GET search endpoint is.
        let form = ["s": query, "type": "1", "offset": "0", "limit": "6"]

        URLSession.shared.dataTask(with: Self.jsonRequest(searchURL, post: form)) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]], !songs.isEmpty,
                  let songId = Self.bestNetEaseSong(songs, title: title, artist: artist, duration: duration),
                  let lyricURL = URL(string: "https://music.163.com/api/song/lyric?os=pc&id=\(songId)&lv=-1&kv=-1&tv=-1") else {
                completion(nil)
                return
            }

            URLSession.shared.dataTask(with: Self.jsonRequest(lyricURL)) { lrcData, _, _ in
                guard let lrcData = lrcData,
                      let lrcJson = try? JSONSerialization.jsonObject(with: lrcData) as? [String: Any],
                      let lrcObj = lrcJson["lrc"] as? [String: Any],
                      let lrcText = lrcObj["lyric"] as? String else {
                    completion(nil)
                    return
                }
                let transText = (lrcJson["tlyric"] as? [String: Any])?["lyric"] as? String
                completion(LyricPayload(lrc: lrcText, translation: transText))
            }.resume()
        }.resume()
    }

    private func fetchLRCLIB(title: String, artist: String, duration: Double, requireCJK: Bool, completion: @escaping (LyricPayload?) -> Void) {
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration)))
        ]
        guard let url = comps?.url else { completion(nil); return }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("GrindIsland/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let synced = json["syncedLyrics"] as? String, !synced.isEmpty else {
                completion(nil)
                return
            }
            // Reject an English translation for an Asian song.
            if requireCJK && !self.hasCJK(synced) { completion(nil); return }
            completion(LyricPayload(lrc: synced, translation: nil))
        }.resume()
    }

    /// Fuzzy search: finds the entry whose length matches the track even when the title is written differently
    /// (e.g. "ハルカ" is listed as "Haruka").
    private func searchLRCLIB(title: String, artist: String, duration: Double, requireCJK: Bool, completion: @escaping (LyricPayload?) -> Void) {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: artist.isEmpty ? title : "\(title) \(artist)")]
        guard let url = comps?.url else { completion(nil); return }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("GrindIsland/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(nil)
                return
            }
            let candidates = list
                .filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
                .filter { duration <= 0 || abs((($0["duration"] as? Double) ?? 0) - duration) <= 4 }
                .sorted { abs((($0["duration"] as? Double) ?? 0) - duration) < abs((($1["duration"] as? Double) ?? 0) - duration) }
            for item in candidates {
                guard let synced = item["syncedLyrics"] as? String else { continue }
                if requireCJK && !self.hasCJK(synced) { continue }
                completion(LyricPayload(lrc: synced, translation: nil))
                return
            }
            completion(nil)
        }.resume()
    }

    static func parseLRC(lrc: String, translationLrc: String?) -> LyricDoc {
        var rawLines: [(time: Double, text: String)] = []
        let pattern = "\\[(\\d{2}):(\\d{2})\\.(\\d{2,3})\\](.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return LyricDoc(lines: []) }

        for line in lrc.components(separatedBy: "\n") {
            let nsStr = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsStr.length))
            if let m = matches.first, m.numberOfRanges >= 5 {
                let mStr = nsStr.substring(with: m.range(at: 1))
                let sStr = nsStr.substring(with: m.range(at: 2))
                let msStr = nsStr.substring(with: m.range(at: 3))
                let text = nsStr.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)

                let mins = Double(mStr) ?? 0
                let secs = Double(sStr) ?? 0
                let msDiv = msStr.count == 3 ? 1000.0 : 100.0
                let ms = (Double(msStr) ?? 0) / msDiv
                let totalSecs = mins * 60 + secs + ms

                if !text.isEmpty && !Self.isPlaceholder(text) && !Self.isCreditLine(text) && !Self.isCopyrightLine(text) {
                    rawLines.append((totalSecs, text))
                }
            }
        }

        // Parse translation map: [timeSecs -> transText]
        var transMap: [Double: String] = [:]
        if let transLrc = translationLrc {
            for line in transLrc.components(separatedBy: "\n") {
                let nsStr = line as NSString
                let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsStr.length))
                if let m = matches.first, m.numberOfRanges >= 5 {
                    let mStr = nsStr.substring(with: m.range(at: 1))
                    let sStr = nsStr.substring(with: m.range(at: 2))
                    let msStr = nsStr.substring(with: m.range(at: 3))
                    let text = nsStr.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)

                    let mins = Double(mStr) ?? 0
                    let secs = Double(sStr) ?? 0
                    let msDiv = msStr.count == 3 ? 1000.0 : 100.0
                    let ms = (Double(msStr) ?? 0) / msDiv
                    let totalSecs = mins * 60 + secs + ms

                    // NetEase puts its notice in the translation too ("(翻译水平有限 授权网易云音乐使用)").
                    if !text.isEmpty && !Self.isPlaceholder(text) && !Self.isCreditLine(text) && !Self.isCopyrightLine(text) {
                        transMap[totalSecs] = text
                    }
                }
            }
        }

        // Build LyricLine array with endTimes
        var finalLines: [LyricLine] = []
        for i in 0..<rawLines.count {
            let item = rawLines[i]
            let nextTime = (i + 1 < rawLines.count) ? rawLines[i + 1].time : (item.time + 5.0)

            // Find closest translation within 0.5s tolerance
            var matchTrans: String? = nil
            for (tTime, tText) in transMap {
                if abs(tTime - item.time) <= 0.5 {
                    matchTrans = tText
                    break
                }
            }

            finalLines.append(LyricLine(
                id: i,
                startTime: item.time,
                endTime: nextTime,
                text: item.text,
                translation: matchTrans
            ))
        }

        return LyricDoc(lines: finalLines)
    }

    /// A line with no words, only a dash or dots ("-", "—", "…"): a slot some files keep for a notice.
    static func isPlaceholder(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.whitespaces).union(.symbols).contains($0) }
            && !text.contains("♪")   // a music note marks a pause on purpose
    }

    /// Credit / metadata lines that lyric files carry at the top ("作词：…", "编曲：…", "Composer: …").
    private static let creditExact: Set<String> = ["词", "詞", "曲", "编", "編", "OP", "SP"]
    private static let creditContains = [
        "作词", "作詞", "作曲", "编曲", "編曲", "制作", "製作", "混音", "母带", "母帶", "录音", "錄音", "和声", "和聲",
        "合声", "吉他", "贝斯", "貝斯", "策划", "监制", "監製", "出品", "发行", "發行", "歌手", "专辑", "專輯", "演唱",
        "原唱", "翻唱", "lyric", "compos", "arrang", "produc", "written", "mixed", "master", "words by", "music by"
    ]

    static func isCreditLine(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= 16 else { return false }
        if creditExact.contains(key) { return true }
        return creditContains.contains { key.localizedCaseInsensitiveContains($0) }
    }

    /// Copyright / licensing notices that some sources append after the last lyric ("(2020年作品)", "授权…使用").
    /// Patterns are narrow on purpose, so a real lyric that merely mentions a year or "授权" is kept.
    private static let copyrightPatterns: [NSRegularExpression] = [
        #"^[（(]\s*\d{4}\s*年\s*作(品)?\s*[）)]$"#,
        #"(授权|授權).{0,30}(使用|翻唱|发行|發行)"#,
        #"(未经|未經).{0,12}(许可|許可|授权|授權)"#,
        #"(版权所有|版權所有|All rights reserved)"#,
        #"^\s*(©|℗|Copyright\b)"#,
        #"(享有|享有本).{0,12}(著作权|著作權)"#,
        #"(著作权人|著作權人)"#,
        #"^\s*(本歌曲|本作品)来自|^\s*(本歌曲|本作品)來自"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isCopyrightLine(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return copyrightPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    private func cleanQuery(_ text: String) -> String {
        var str = text
        // Strip trailing subtitle patterns like " - Spinning Globe", " (feat. ...)"
        if let range = str.range(of: " - ") {
            str = String(str[..<range.lowerBound])
        }
        if let range = str.range(of: " (feat.") {
            str = String(str[..<range.lowerBound])
        }
        if let range = str.range(of: " (with ") {
            str = String(str[..<range.lowerBound])
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            // CJK Unified Ideographs, Hiragana, Katakana, Hangul
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3040...0x309F).contains(scalar.value) ||
               (0x30A0...0x30FF).contains(scalar.value) ||
               (0xAC00...0xD7AF).contains(scalar.value) {
                return true
            }
        }
        return false
    }
}

/// Receiver for the display link's callback.
private final class SyncTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func tick(_ link: CADisplayLink) { block() }
}

/// The sung share of the expanded page's current line, updated every frame. Kept apart from LyricService so only
/// the view that draws it redraws (not the whole island).
final class LyricProgress: ObservableObject {
    static let shared = LyricProgress()
    @Published var expanded: CGFloat = 0
}
