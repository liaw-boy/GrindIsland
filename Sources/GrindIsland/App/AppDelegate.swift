import Combine
import CoreAudio
import AppKit
import SwiftUI

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelSync: AnyCancellable?
    private var screenSync: NSObjectProtocol?
    private var notchPanel: NotchPanel?

    /// Quitting (or a Sparkle update restarting the app) mid-recording: stop it so the movie is written and no
    /// orphaned recorder keeps going without a stop button.
    public func applicationWillTerminate(_ notification: Notification) {
        ScreenRecorder.shared.stop()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()   // before the menu, which shows "檢查更新…" only when updates are available
        // 1. Setup Status Bar Menu Item
        setupStatusBarItem()

        // Drop cached lyrics of songs that were not played for a while.
        LyricCache.shared.purgeExpired(days: LyricCache.retentionDays)

        // 2. Start Core Background Trackers
        // `--simulate-idle` never starts the music tracker, to check the "nothing playing" state.
        if !CommandLine.arguments.contains("--simulate-idle") { MusicTracker.shared.start() }
        AgentMonitor.shared.start()
        BatteryMonitor.shared.start()
        VolumeMonitor.shared.start()
        BrightnessMonitor.shared.start()
        MediaKeys.shared.apply(enabled: AppSettings.shared.takeOverMediaKeys)
        ClipboardHistory.shared.apply(enabled: AppSettings.shared.clipboardHistory)
        HotKeys.shared.apply(AppSettings.shared.islandHotkey)
        ScreenshotShelf.shared.apply(enabled: AppSettings.shared.screenshotShelf)
        // `--test-clipboard` (with the setting on) fills the history with made-up text, for screenshots.
        if CommandLine.arguments.contains("--test-clipboard") {
            for t in ["https://example.com/docs/getting-started", "let total = items.reduce(0, +)", "Meeting moved to 3 pm"] {
                ClipboardHistory.shared.add(t)
            }
        }
        SystemEvents.shared.start()
        // `--test-volume-at=N` shows the volume indicator stepping 40% → 70% N seconds after launch (no real change).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-volume-at=") }),
           let seconds = Double(arg.dropFirst("--test-volume-at=".count)) {
            for (i, v) in [0.4, 0.5, 0.6, 0.7].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds + Double(i) * 0.25) {
                    NoticeCenter.shared.post(VolumeMonitor.notice(volume: Float(v), muted: false), seconds: 1.6)
                }
            }
        }
        // `--test-headphones-at=N` shows the "headphones connected" notice N seconds after launch, with the battery of
        // earbuds connected right now if any (made-up levels otherwise; no reconnect needed).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-headphones-at=") }),
           let seconds = Double(arg.dropFirst("--test-headphones-at=".count)) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                let real = CommandLine.arguments.contains("--test-fake-battery") ? nil : VolumeMonitor.bluetoothReport().flatMap { VolumeMonitor.budBattery(json: $0, name: "") }
                let b = real ?? .init(left: 98, right: 97, case_: 84, main: nil)
                NoticeCenter.shared.post(VolumeMonitor.deviceNotice(name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth, battery: b), seconds: 6)
            }
        }
        // `--test-brightness-at=N` shows the display, then the keyboard brightness indicator (no real change).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-brightness-at=") }),
           let seconds = Double(arg.dropFirst("--test-brightness-at=".count)) {
            for (i, v) in [0.5, 0.56, 0.62].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds + Double(i) * 0.25) {
                    NoticeCenter.shared.post(BrightnessMonitor.notice(level: Float(v), keyboard: false), seconds: 1.6)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 3) {
                NoticeCenter.shared.post(BrightnessMonitor.notice(level: 0.75, keyboard: true), seconds: 1.6)
            }
        }
        // `--render-change-preview=<file.png>` draws the approval card's edit preview off screen, then quits.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--render-change-preview=") }) {
            let out = URL(fileURLWithPath: String(arg.dropFirst("--render-change-preview=".count)))
            let input: [String: Any] = ["file_path": "/tmp/demo/Greeter.swift",
                                        "old_string": "func greet() {\n\tprint(\"hi\")\n}",
                                        "new_string": "func greet(name: String) {\n\tprint(\"hi, \\(name)\")\n}"]
            let view = ChangePreview(lines: ApprovalRequest.changes(input) ?? [], scrolls: false).frame(width: 300).padding(8).background(Color.black)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: out)
            }
            exit(0)
        }
        // `--test-shelf=<folder>` puts that folder's files on the shelf (only for the bare executable's own settings).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-shelf=") }) {
            let dir = URL(fileURLWithPath: String(arg.dropFirst("--test-shelf=".count)))
            ShelfStore.shared.add((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        }
        // `--test-pending=<sessionId>` adds a made-up permission request for that session, collapsed (test socket only).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-pending=") }) {
            let d = ApprovalRequest.describe(tool: "Bash", input: ["command": "ls -la", "description": "List the demo folder"])
            let req = ApprovalRequest(sessionId: String(arg.dropFirst("--test-pending=".count)), cwd: "/tmp/demo", tool: "Bash",
                                      summary: d.summary, detail: d.detail, complete: d.complete, summaryIsInput: d.summaryIsInput)
            AgentMonitor.shared.pendingApprovals.append(AgentMonitor.PendingApproval(request: req))
        }
        // `--test-review` opens the approval review with a made-up edit request (test socket only; nothing waits on it).
        if CommandLine.arguments.contains("--test-review") {
            let input: [String: Any] = ["file_path": "/tmp/demo/Greeter.swift",
                                        "old_string": "func greet() {\n\tprint(\"hi\")\n}",
                                        "new_string": "func greet(name: String) {\n\tprint(\"hi, \\(name)\")\n}"]
            let d = ApprovalRequest.describe(tool: "Edit", input: input)
            let req = ApprovalRequest(sessionId: "demo", cwd: "/tmp/demo", tool: "Edit", summary: d.summary, detail: d.detail,
                                      complete: d.complete, summaryIsInput: d.summaryIsInput, changes: d.changes)
            let p = AgentMonitor.PendingApproval(request: req)
            AgentMonitor.shared.pendingApprovals.append(p)
            NotchGeometry.shared.reviewingApproval = p.id
            NotchGeometry.shared.isExpanded = true
        }
        // `--test-record=<folder>` records 3 s into that folder (not the Desktop), to check the island while recording.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-record=") }) {
            let dir = URL(fileURLWithPath: String(arg.dropFirst("--test-record=".count)), isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ScreenRecorder.shared.start(into: dir) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { ScreenRecorder.shared.stop() }
        }
        CalendarService.shared.start()   // only if access was granted before; never asks at launch
        // `--test-timer` starts a 25/5 focus timer at launch (to check its displays without clicking).
        if CommandLine.arguments.contains("--test-timer") { FocusTimer.shared.start(FocusClock.presets[0]) }
        // `--test-month=2027-01` opens the mini calendar on that month (to check a six-week month's layout).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-month=") }) {
            let p = arg.dropFirst("--test-month=".count).split(separator: "-").compactMap { Int($0) }
            if p.count == 2, let m = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: 1)) {
                CalendarService.shared.shownMonth = m
            }
        }
        // `--test-charge-at=N` shows the "charger connected" notice N seconds after launch (no real plug needed).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-charge-at=") }),
           let seconds = Double(arg.dropFirst("--test-charge-at=".count)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let p = BatteryMonitor.read()?.percent ?? 80
                if let n = BatteryMonitor.notice(from: .init(percent: p, onAC: false), to: .init(percent: p, onAC: true)) {
                    NoticeCenter.shared.post(n)
                }
            }
        }
        // `GRINDISLAND_APPROVAL_SOCKET` lets a test run use its own socket without touching the installed app's.
        AgentMonitor.shared.startApprovals(socketPath: ProcessInfo.processInfo.environment["GRINDISLAND_APPROVAL_SOCKET"] ?? ApprovalWire.socketPath())

        // 3. Display Native Dynamic Island Panel
        self.notchPanel = NotchPanel.shared
        self.notchPanel?.applyVisibility()
        // "所有螢幕": one more island per other display, following the setting and displays coming and going.
        NotchPanel.syncExtraPanels()
        panelSync = AppSettings.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { _ in DispatchQueue.main.async { NotchPanel.syncExtraPanels() } }
        screenSync = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                            object: nil, queue: .main) { _ in
            DispatchQueue.main.async { NotchPanel.syncExtraPanels() }
        }

        // `--open-at-launch` expands the island without the pointer on it (to check the auto-collapse).
        if CommandLine.arguments.contains("--open-at-launch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.68)) { NotchGeometry.shared.isExpanded = true }
            }
        }

        // `--test-menu` opens our own status bar menu at 2s and closes it at 7s (to check that lyrics keep running
        // while a menu is open) without anybody clicking.
        if CommandLine.arguments.contains("--test-menu") {
            Timer.commonModeTimer(interval: 2.0, repeats: false) { [weak self] _ in
                Timer.commonModeTimer(interval: 5.0, repeats: false) { [weak self] _ in self?.statusItem?.menu?.cancelTracking() }
                self?.statusItem?.button?.performClick(nil)
            }
        }

        // `--preview-resident`: show the mock-up of the planned always-on capsule (see ResidentPreviewView).
        ResidentPreviewWindow.showIfRequested()

        // `--test-panel-map` logs which cmux panel each agent session was matched to (read-only, nothing is focused).
        if CommandLine.arguments.contains("--test-panel-map") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                for s in AgentMonitor.shared.sessions {
                    let folder = URL(fileURLWithPath: s.cwd).lastPathComponent
                    NSLog("PANELMAP %@ -> %@", folder, AgentMonitor.cmuxPanelID(ofProcess: s.pid) ?? "none")
                }
            }
        }

        // `--test-jump=<folder name>` jumps to the agent session whose project folder has that name, 4 seconds after
        // launch (the same action as the card's arrow), so the jump can be checked without a click.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-jump=") }) {
            let folder = String(arg.dropFirst("--test-jump=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if let s = AgentMonitor.shared.sessions.first(where: { URL(fileURLWithPath: $0.cwd).lastPathComponent == folder }) {
                    AgentMonitor.shared.focusHost(of: s)
                } else {
                    NSLog("GrindIsland: test-jump found no session for folder %@", folder)
                }
            }
        }

        // `--test-gear` runs the gear button's action 3 seconds after launch (to check it without a click).
        if CommandLine.arguments.contains("--test-gear") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { NotchGeometry.shared.collapseAndShowSettings() }
        }

        // `--settings` opens the settings window at launch (used for visual verification).
        if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        }
    }

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: "music.note.house.fill", accessibilityDescription: "GrindIsland")?.withSymbolConfiguration(config)
        button.toolTip = "GrindIsland: 動態歌詞 & 像素 Agent 工位"

        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "GrindIsland 🏝️", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "展開 / 摺疊動態島", action: #selector(toggleNotch), keyEquivalent: "d")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if Updater.shared.available {
            let updateItem = NSMenuItem(title: "檢查更新…", action: #selector(checkUpdates), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let refreshMusicItem = NSMenuItem(title: "重新抓取目前歌曲與歌詞", action: #selector(refreshMusic), keyEquivalent: "r")
        refreshMusicItem.target = self
        menu.addItem(refreshMusicItem)

        let recordItem = NSMenuItem(title: "螢幕錄影：開始／停止", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        let refreshAgentItem = NSMenuItem(title: "重新掃描本機 Agents", action: #selector(refreshAgents), keyEquivalent: "")
        refreshAgentItem.target = self
        menu.addItem(refreshAgentItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "結束 GrindIsland", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func checkUpdates() { Updater.shared.checkNow() }
    @objc private func toggleRecording() { ScreenRecorder.shared.toggle() }

    @objc private func toggleNotch() {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                NotchGeometry.shared.isExpanded.toggle()
            }
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func refreshMusic() {
        MusicTracker.shared.poll()
    }

    @objc private func refreshAgents() {
        AgentMonitor.shared.scan()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
