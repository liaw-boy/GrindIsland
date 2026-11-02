import AppKit
import SwiftUI

/// Screen recording from the island (設定 › 功能 › 螢幕錄影): macOS's own `screencapture -v` records the display under
/// the pointer; the collapsed island shows the time and a stop button, so nothing needs the menu bar.
/// The movie goes to the screenshot folder (and so shows up on the screenshot shelf).
final class ScreenRecorder: ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var started: Date?
    @Published private(set) var now = Date()
    var recording: Bool { started != nil }

    private var process: Process?
    private var ticker: Timer?
    private var file: URL?

    func toggle() { recording ? stop() : start() }

    /// `folder` is for tests (`--test-record=`); normally the screenshot folder.
    func start(into folder: URL? = nil) {
        guard process == nil, AppSettings.shared.screenRecording else { return }
        let mouse = NSEvent.mouseLocation
        let index = (NSScreen.screens.firstIndex { $0.frame.contains(mouse) } ?? 0) + 1   // screencapture counts from 1
        let out = (folder ?? ScreenshotShelf.folder).appendingPathComponent(Self.fileName(at: Date()))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-v", "-k", "-x", "-D", String(index), out.path]   // video, show clicks, no sound
        p.terminationHandler = { [weak self] proc in DispatchQueue.main.async { self?.finished(proc) } }
        do { try p.run() } catch { return }
        process = p
        file = out
        started = Date()
        now = Date()
        ticker = Timer.commonModeTimer(interval: 1, repeats: true) { [weak self] _ in self?.now = Date() }
    }

    /// A screenshot of an area or a window you pick (macOS's own crosshair), into the screenshot folder.
    func screenshot() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let out = ScreenshotShelf.folder.appendingPathComponent("截圖 \(f.string(from: Date())).png")
        // The island closes first, so it is not in the way of the selection.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { NotchGeometry.all.allObjects.forEach { $0.isExpanded = false } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", out.path]   // interactive: drag an area, or Space for a window; Esc cancels
            try? p.run()
        }
    }

    /// Ctrl-C to screencapture: it stops and writes the movie.
    func stop() { process?.interrupt() }

    private func finished(_ p: Process) {
        let ran = started.map { Date().timeIntervalSince($0) } ?? 0
        ticker?.invalidate(); ticker = nil
        process = nil
        started = nil
        let saved = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if saved {
            NoticeCenter.shared.post(IslandNotice(icon: "record.circle", tint: .white, title: "錄影已儲存",
                                                  detail: file?.lastPathComponent ?? "", trailing: "✓"), seconds: 3)
        } else if ran < 3 {
            // Ended at once without a file: most likely no Screen Recording permission yet.
            NoticeCenter.shared.post(IslandNotice(icon: "exclamationmark.triangle.fill", tint: .orange, title: "無法錄影",
                                                  detail: "到「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許 GrindIsland", trailing: "!"), seconds: 5)
        }
        file = nil
    }

    /// "螢幕錄影 2026-11-02 21.05.33.mov", like macOS names its own recordings.
    static func fileName(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "螢幕錄影 \(f.string(from: date)).mov"
    }

    /// "1:05" / "12:30" / "1:02:03".
    static func elapsed(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
