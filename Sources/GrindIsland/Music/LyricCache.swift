import Foundation
import CryptoKit

/// What a lyric source returned, before parsing: the synced lyric text and an optional translation.
/// The cache stores this (not the parsed lines), so later improvements to parsing / filtering also apply to
/// songs that were cached earlier.
struct LyricPayload: Codable, Equatable {
    var lrc: String
    var translation: String?
}

/// Lyrics on disk (~/Library/Application Support/GrindIsland/lyrics). File names are a hash of the track
/// identity, so no external text is ever used as a path component and no title or artist is written to disk.
final class LyricCache {
    static let shared = LyricCache()

    private struct Entry: Codable {
        var payload: LyricPayload
        var savedAt: Date
    }

    /// Songs not played for this many days are removed.
    static let retentionDays = 14
    private let maxEntries = 800
    /// A file's modification time doubles as "last played": playing a cached song refreshes it, so songs you keep
    /// listening to never expire and songs left alone for a while are cleaned up.
    private let touchInterval: TimeInterval = 3600
    private let queue = DispatchQueue(label: "com.grindisland.lyriccache", qos: .utility)
    private let directory: URL

    /// `directory` is only passed by tests; the app uses the default location.
    init(directory: URL? = nil) {
        if let directory = directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("GrindIsland", isDirectory: true).appendingPathComponent("lyrics", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    /// Reads off the main thread and calls back on it. A hit refreshes the song's "last played" time; a file that
    /// has not been played for more than `days` days is deleted and counts as a miss.
    func load(key: String, days: Int, completion: @escaping (LyricPayload?) -> Void) {
        queue.async { [fileURL = fileURL(forKey: key), touchInterval] in
            var result: LyricPayload?
            if let data = try? Data(contentsOf: fileURL),
               let entry = try? JSONDecoder().decode(Entry.self, from: data) {
                let lastPlayed = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? entry.savedAt
                let age = Date().timeIntervalSince(lastPlayed)
                if age > Double(days) * 86400 {
                    try? FileManager.default.removeItem(at: fileURL)
                } else {
                    result = entry.payload
                    if age > touchInterval {   // refresh "last played" (at most once an hour per song)
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
                    }
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Deletes every song that has not been played for more than `days` days (run at launch).
    func purgeExpired(days: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let limit = Date().addingTimeInterval(-Double(days) * 86400)
            for url in self.files() {
                let last = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if last < limit { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    func store(key: String, payload: LyricPayload) {
        queue.async { [weak self] in
            guard let self = self,
                  let data = try? JSONEncoder().encode(Entry(payload: payload, savedAt: Date())) else { return }
            try? data.write(to: self.fileURL(forKey: key), options: .atomic)
            self.trim()
        }
    }

    /// Number of cached songs (for the settings window).
    func count() -> Int {
        queue.sync { files().count }
    }

    func clear() {
        queue.sync { files().forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    /// Keeps the `maxEntries` most recently played files.
    private func trim() {
        let all = files()
        guard all.count > maxEntries else { return }
        let dated = all.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(all.count - maxEntries) { try? FileManager.default.removeItem(at: url) }
    }
}
