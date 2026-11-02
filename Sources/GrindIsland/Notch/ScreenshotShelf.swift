import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Recent screenshots (設定 › 功能 › 截圖暫存區, off by default): found with Spotlight, which tags every screenshot
/// (kMDItemIsScreenCapture), in the folder macOS saves them to; the last day, newest first. Nothing is copied.
final class ScreenshotShelf: ObservableObject {
    static let shared = ScreenshotShelf()
    static let maxItems = 30
    /// How far back the shelf shows screenshots (設定: 1 / 3 / 7 days).
    static var keepSeconds: TimeInterval { Double(max(1, AppSettings.shared.screenshotKeepDays)) * 86400 }

    struct Shot: Identifiable, Equatable {
        var id: String { url.path }
        let url: URL
        let date: Date
    }

    @Published private(set) var shots: [Shot] = []
    @Published private(set) var thumbs: [String: NSImage] = [:]

    private var query: NSMetadataQuery?
    private var known = Set<String>()
    private var started = Date()

    /// Where macOS saves screenshots (the user's choice in the Screenshot app, else the Desktop).
    static var folder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { ($0 as NSString).expandingTildeInPath }
        if let c = custom, FileManager.default.fileExists(atPath: c) { return URL(fileURLWithPath: c, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func apply(enabled: Bool) {
        cleanTimer?.invalidate(); cleanTimer = nil
        query?.stop(); query = nil
        NotificationCenter.default.removeObserver(self)
        guard enabled else { shots = []; thumbs = [:]; known = []; return }
        started = Date()
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemContentCreationDate >= %@",
                                  Date().addingTimeInterval(-Self.keepSeconds) as NSDate)
        q.searchScopes = [Self.folder]
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)]
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(self, selector: #selector(update), name: name, object: q)
        }
        q.start()
        query = q
        // Old screenshots to the Trash (when turned on): now and every hour.
        cleanUp()
        cleanTimer = Timer.commonModeTimer(interval: 3600, repeats: true) { [weak self] _ in self?.cleanUp() }
    }

    private var cleanTimer: Timer?
    private var cleanQuery: NSMetadataQuery?

    /// Screenshots unused for `screenshotTrashDays` days (last opened, else taken) move to the Trash. Only files
    /// Spotlight marks as screenshots, directly in the screenshot folder; the Trash keeps them recoverable.
    func cleanUp() {
        let days = AppSettings.shared.screenshotTrashDays
        guard days > 0, cleanQuery == nil else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        q.searchScopes = [Self.folder]
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            q.stop()
            if let t = token { NotificationCenter.default.removeObserver(t) }
            self?.cleanQuery = nil
            let folder = Self.folder.standardizedFileURL.path
            let found: [(url: URL, created: Date, lastUsed: Date?)] = q.results.compactMap { r in
                guard let item = r as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                let url = URL(fileURLWithPath: path)
                guard url.deletingLastPathComponent().standardizedFileURL.path == folder,   // that folder only
                      Self.ownName(url.lastPathComponent) else { return nil }               // named like a capture made here
                return (url, item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? Date(),
                        item.value(forAttribute: "kMDItemLastUsedDate") as? Date)
            }
            let old = Self.stale(found, now: Date(), days: days)
            guard !old.isEmpty else { return }
            NSWorkspace.shared.recycle(old) { moved, _ in
                guard !moved.isEmpty else { return }
                DispatchQueue.main.async {
                    NoticeCenter.shared.post(IslandNotice(icon: "trash", tint: .white, title: "清除舊截圖",
                                                          detail: "\(moved.count) 張超過 \(days) 天沒用的截圖已移到垃圾桶", trailing: "\(moved.count)"), seconds: 3)
                }
            }
        }
        cleanQuery = q
        q.start()
    }

    /// Names macOS (and this app) give its own captures; a screenshot someone sent you keeps its own name and is
    /// never cleaned up.
    static func ownName(_ name: String) -> Bool {
        ["截圖 ", "截屏", "螢幕截圖", "螢幕快照", "螢幕錄影 ", "Screenshot ", "Screen Shot ", "Screen Recording "].contains { name.hasPrefix($0) }
    }

    /// The screenshots not used (opened, else taken) within `days`.
    static func stale(_ shots: [(url: URL, created: Date, lastUsed: Date?)], now: Date, days: Int) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return shots.filter { max($0.created, $0.lastUsed ?? .distantPast) < cutoff }.map(\.url)
    }

    @objc private func update() {
        guard let q = query else { return }
        q.disableUpdates(); defer { q.enableUpdates() }
        let now = Date()
        var list: [Shot] = []
        for case let item as NSMetadataItem in q.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let date = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? now
            if now.timeIntervalSince(date) < Self.keepSeconds { list.append(Shot(url: URL(fileURLWithPath: path), date: date)) }
        }
        list = Array(list.sorted { $0.date > $1.date }.prefix(Self.maxItems))
        // A screenshot taken just now: say so on the island.
        if let newest = list.first, !known.contains(newest.id), newest.date > started {
            NoticeCenter.shared.post(IslandNotice(icon: "camera.viewfinder", tint: .white, title: "已截圖",
                                                  detail: "放在暫存的「截圖」裡，可以直接拖出去", trailing: "✓"), seconds: 2.5)
        }
        known = Set(list.map(\.id))
        if list != shots { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { shots = list } }
        thumbs = thumbs.filter { known.contains($0.key) }   // thumbnails only for what is still shown
        for s in list where thumbs[s.id] == nil { thumbnail(s) }
    }

    /// Thumbnails are drawn by Quick Look (another process), so the app never decodes the image itself.
    private func thumbnail(_ s: Shot) {
        let req = QLThumbnailGenerator.Request(fileAt: s.url, size: CGSize(width: 120, height: 80), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbs[s.id] = img }
        }
    }

    /// The image itself on the clipboard (to paste into a chat or a document).
    func copy(_ s: Shot) {
        guard let img = NSImage(contentsOf: s.url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        NoticeCenter.shared.post(IslandNotice(icon: "doc.on.clipboard.fill", tint: .white, title: "已複製",
                                              detail: "截圖已複製，可以直接貼上", trailing: "✓"), seconds: 1.4)
    }

    /// Moves the file to the Trash (asked from its context menu; it can be put back from there).
    func trash(_ s: Shot) {
        NSWorkspace.shared.recycle([s.url]) { [weak self] _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { withAnimation { self?.shots.removeAll { $0 == s } } }
        }
    }
}

/// The 暫存 page's "截圖" side: thumbnails, newest first.
struct ScreenshotView: View {
    @ObservedObject private var shelf = ScreenshotShelf.shared

    var body: some View {
        Group {
            if shelf.shots.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 22)).foregroundColor(.white.opacity(0.5))
                    Text("最近的截圖會出現在這裡（⇧⌘3 / ⇧⌘4）").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { ForEach(shelf.shots) { tile($0) } }
                        .padding(.horizontal, 22).padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(_ s: ScreenshotShelf.Shot) -> some View {
        VStack(spacing: 4) {
            Group {
                if let img = shelf.thumbs[s.id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 104, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            Text(s.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 9.5)).monospacedDigit()
                .foregroundColor(.white.opacity(0.5))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(s.url) }
        .onTapGesture { shelf.copy(s) }
        .onDrag { NSItemProvider(contentsOf: s.url) ?? NSItemProvider() }
        .contextMenu {
            Button("複製圖片") { shelf.copy(s) }
            Button("打開") { NSWorkspace.shared.open(s.url) }
            Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
            Divider()
            Button("移到垃圾桶") { shelf.trash(s) }
        }
        .help("點一下複製、雙擊打開、可以直接拖出去")
    }
}
