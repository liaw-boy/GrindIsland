import SwiftUI
import AppKit

/// How the island is drawn: `notch` = wings beside the notch with the lyric hanging below; `capsule` = a floating
/// capsule (like the iPhone's Dynamic Island); `attached` = a capsule that grows out of the notch's lower edge and
/// folds back into it. `auto` = attached on a display with a notch, capsule otherwise.
enum IslandStyle: String, CaseIterable, Identifiable {
    case auto, notch, capsule, attached
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自動"
        case .notch: return "瀏海"
        case .capsule: return "膠囊"
        case .attached: return "融合"
        }
    }
}

/// User preferences, persisted in UserDefaults. Only what a user really needs to decide lives here; everything
/// else is a fixed, sensible behavior of the island. Geometry and the panel subscribe to `objectWillChange`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Localized name of the display to use; empty means "automatic" (built-in notched display).
    @Published var targetScreenName: String { didSet { defaults.set(targetScreenName, forKey: "targetScreenName") } }
    @Published var islandStyle: IslandStyle { didSet { defaults.set(islandStyle.rawValue, forKey: "islandStyle") } }
    /// Hide the island while nothing is playing (paused counts as not playing) and no agent needs attention.
    @Published var autoHideWhenIdle: Bool { didSet { defaults.set(autoHideWhenIdle, forKey: "autoHideWhenIdle") } }
    @Published var hoverToOpen: Bool { didSet { defaults.set(hoverToOpen, forKey: "hoverToOpen") } }
    /// How far (pt) outside the island the pointer still wakes it; 0 = the pointer must touch the island.
    @Published var edgeSensitivity: Double { didSet { defaults.set(edgeSensitivity, forKey: "edgeSensitivity") } }
    /// Multiplier for the lyric size of the collapsed island (1.0 = default). The expanded view is fixed.
    @Published var lyricFontScale: Double { didSet { defaults.set(lyricFontScale, forKey: "lyricFontScale") } }
    /// Show translations (when the lyric source has one), in both the collapsed and the expanded island.
    @Published var showTranslation: Bool { didSet { defaults.set(showTranslation, forKey: "showTranslation") } }
    /// Collapsed island only: false = translation under the lyric (上下), true = beside it (左右).
    @Published var translationSideBySide: Bool { didSet { defaults.set(translationSideBySide, forKey: "translationSideBySide") } }
    /// Show translations in Traditional Chinese (the lyric source delivers Simplified).
    @Published var translationTraditional: Bool { didSet { defaults.set(translationTraditional, forKey: "translationTraditional") } }
    /// Seconds added to the playback clock when choosing the lyric line (positive = lyrics earlier).
    @Published var lyricLead: Double { didSet { defaults.set(lyricLead, forKey: "lyricLead") } }
    /// Island notices from the Mac itself.
    @Published var batteryNotices: Bool { didSet { defaults.set(batteryNotices, forKey: "batteryNotices") } }
    @Published var volumeNotices: Bool { didSet { defaults.set(volumeNotices, forKey: "volumeNotices") } }
    @Published var meetingAlerts: Bool { didSet { defaults.set(meetingAlerts, forKey: "meetingAlerts") } }
    @Published var systemNotices: Bool { didSet { defaults.set(systemNotices, forKey: "systemNotices") } }
    @Published var inputSourceNotices: Bool { didSet { defaults.set(inputSourceNotices, forKey: "inputSourceNotices") } }
    /// Features (設定 › 功能): token use from Claude Code's transcripts, and which expanded pages are shown.
    @Published var usageStats: Bool { didSet { defaults.set(usageStats, forKey: "usageStats") } }
    /// The collapsed island's ✓ allows at once (without opening the card), for requests the card shows in full.
    @Published var quickApprove: Bool { didSet { defaults.set(quickApprove, forKey: "quickApprove") } }
    /// Volume / brightness / keyboard-light keys handled by the island (no system on-screen indicator).
    /// A rim in the cover's colour around the island while music plays.
    @Published var edgeLight: Bool { didSet { defaults.set(edgeLight, forKey: "edgeLight") } }
    /// The open/close shortcut (`HotKeys.choices` id).
    @Published var islandHotkey: String {
        didSet { defaults.set(islandHotkey, forKey: "islandHotkey"); HotKeys.shared.apply(islandHotkey) }
    }
    /// Screenshots: days shown on the shelf, and days unused before they go to the Trash (0 = never).
    @Published var screenshotKeepDays: Int {
        didSet { defaults.set(screenshotKeepDays, forKey: "screenshotKeepDays"); ScreenshotShelf.shared.apply(enabled: screenshotShelf) }
    }
    @Published var screenshotTrashDays: Int {
        didSet { defaults.set(screenshotTrashDays, forKey: "screenshotTrashDays"); ScreenshotShelf.shared.cleanUp() }
    }
    /// Recent screenshots on the 暫存 page.
    @Published var screenshotShelf: Bool {
        didSet { defaults.set(screenshotShelf, forKey: "screenshotShelf"); ScreenshotShelf.shared.apply(enabled: screenshotShelf) }
    }
    /// Start / stop screen recording from the island (暫存 page, status menu).
    @Published var screenRecording: Bool { didSet { defaults.set(screenRecording, forKey: "screenRecording") } }
    /// Hours an unpinned clipboard item is kept (1 / 24 / 168).
    @Published var clipboardKeepHours: Int { didSet { defaults.set(clipboardKeepHours, forKey: "clipboardKeepHours") } }
    /// Recent copied text on the 暫存 page (memory only).
    @Published var clipboardHistory: Bool {
        didSet { defaults.set(clipboardHistory, forKey: "clipboardHistory"); ClipboardHistory.shared.apply(enabled: clipboardHistory) }
    }
    @Published var takeOverMediaKeys: Bool {
        didSet { defaults.set(takeOverMediaKeys, forKey: "takeOverMediaKeys"); MediaKeys.shared.apply(enabled: takeOverMediaKeys) }
    }
    @Published var hiddenTabs: Set<Int> { didSet { defaults.set(hiddenTabs.sorted(), forKey: "hiddenTabs") } }

    static let defaultLyricLead = 0.35
    /// `targetScreenName` value for "an island on every display".
    static let allScreens = "*"

    private init() {
        defaults.register(defaults: [
            "targetScreenName": "",
            "islandStyle": IslandStyle.auto.rawValue,
            "autoHideWhenIdle": true,
            "hoverToOpen": false,
            "edgeSensitivity": 10.0,
            "lyricFontScale": 1.0,
            "showTranslation": true,
            "translationSideBySide": false,
            "translationTraditional": true,
            "lyricLead": AppSettings.defaultLyricLead,
            "batteryNotices": true,
            "volumeNotices": true,
            "meetingAlerts": true,
            "systemNotices": true,
            "inputSourceNotices": false,
            "usageStats": true,
            "quickApprove": false,
            "takeOverMediaKeys": false,
            "clipboardHistory": false,
            "islandHotkey": "ctrl-opt-space",
            "screenshotShelf": false,
            "edgeLight": true,
            "clipboardKeepHours": 24,
            "screenRecording": true,
            "screenshotKeepDays": 1,
            "screenshotTrashDays": 0
        ])
        targetScreenName = defaults.string(forKey: "targetScreenName") ?? ""
        islandStyle = IslandStyle(rawValue: defaults.string(forKey: "islandStyle") ?? "") ?? .auto
        autoHideWhenIdle = defaults.bool(forKey: "autoHideWhenIdle")
        hoverToOpen = defaults.bool(forKey: "hoverToOpen")
        edgeSensitivity = min(max(defaults.double(forKey: "edgeSensitivity"), 0), 60)
        lyricFontScale = min(max(defaults.double(forKey: "lyricFontScale"), 0.6), 1.5)
        showTranslation = defaults.bool(forKey: "showTranslation")
        translationSideBySide = defaults.bool(forKey: "translationSideBySide")
        translationTraditional = defaults.bool(forKey: "translationTraditional")
        lyricLead = min(max(defaults.double(forKey: "lyricLead"), -1), 1)
        batteryNotices = defaults.bool(forKey: "batteryNotices")
        volumeNotices = defaults.bool(forKey: "volumeNotices")
        meetingAlerts = defaults.bool(forKey: "meetingAlerts")
        systemNotices = defaults.bool(forKey: "systemNotices")
        inputSourceNotices = defaults.bool(forKey: "inputSourceNotices")
        usageStats = defaults.bool(forKey: "usageStats")
        quickApprove = defaults.bool(forKey: "quickApprove")
        takeOverMediaKeys = defaults.bool(forKey: "takeOverMediaKeys")
        clipboardHistory = defaults.bool(forKey: "clipboardHistory")
        screenshotShelf = defaults.bool(forKey: "screenshotShelf")
        edgeLight = defaults.bool(forKey: "edgeLight")
        screenRecording = defaults.bool(forKey: "screenRecording")
        clipboardKeepHours = [1, 24, 168].contains(defaults.integer(forKey: "clipboardKeepHours")) ? defaults.integer(forKey: "clipboardKeepHours") : 24
        screenshotKeepDays = [1, 3, 7].contains(defaults.integer(forKey: "screenshotKeepDays")) ? defaults.integer(forKey: "screenshotKeepDays") : 1
        screenshotTrashDays = [0, 3, 7, 30].contains(defaults.integer(forKey: "screenshotTrashDays")) ? defaults.integer(forKey: "screenshotTrashDays") : 0
        let hk = defaults.string(forKey: "islandHotkey") ?? ""
        islandHotkey = HotKeys.choices.contains { $0.id == hk } ? hk : "ctrl-opt-space"
        let hidden = Set((defaults.array(forKey: "hiddenTabs") as? [Int] ?? []).filter { (0...6).contains($0) })
        hiddenTabs = hidden.count >= 7 ? [] : hidden   // never every page
    }

    /// The display the island lives on: the chosen one, else the notched built-in display, else the main one.
    var targetScreen: NSScreen {
        if !targetScreenName.isEmpty, let s = NSScreen.screens.first(where: { $0.localizedName == targetScreenName }) {
            return s
        }
        // No display at all for a moment (sleep, unplugging): a blank screen object instead of a crash.
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? NSScreen()
    }

    func resetLyricLead() { lyricLead = AppSettings.defaultLyricLead }
}
