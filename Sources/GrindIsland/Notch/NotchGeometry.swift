import SwiftUI
import AppKit
import Combine

public struct NotchShape: Shape {
    public var cornerRadius: CGFloat
    public var earRadius: CGFloat

    public var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    public init(cornerRadius: CGFloat = 12, earRadius: CGFloat = 6) {
        self.cornerRadius = cornerRadius
        self.earRadius = earRadius
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()

        let w = rect.width
        let h = rect.height
        let ear = earRadius
        let cr = cornerRadius

        // Top-left shoulder
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: ear, y: ear), control: CGPoint(x: ear, y: 0))

        // Down to bottom-left corner
        path.addLine(to: CGPoint(x: ear, y: h - cr))
        path.addArc(
            center: CGPoint(x: ear + cr, y: h - cr),
            radius: cr,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Across bottom to bottom-right corner
        path.addLine(to: CGPoint(x: w - ear - cr, y: h))
        path.addArc(
            center: CGPoint(x: w - ear - cr, y: h - cr),
            radius: cr,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Up to top-right shoulder
        path.addLine(to: CGPoint(x: w - ear, y: ear))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - ear, y: 0))

        path.closeSubpath()
        return path
    }
}

public final class NotchGeometry: ObservableObject {
    /// The main island (the display chosen in settings). With "所有螢幕" every other display gets its own instance.
    public static let shared = NotchGeometry()
    /// Every live island (one per display shown).
    static let all = NSHashTable<NotchGeometry>.weakObjects()
    /// Any island open (e.g. the expanded lyric page needs per-frame progress).
    static var anyExpanded: Bool { all.allObjects.contains { $0.isExpanded } }

    /// The display this island lives on: a fixed one for the extra islands (by display number, which stays unique
    /// even for two monitors of the same model), else the one chosen in settings.
    let screenID: CGDirectDisplayID?
    var screen: NSScreen {
        screenID.flatMap { id in NSScreen.screens.first { Self.displayID(of: $0) == id } } ?? AppSettings.shared.targetScreen
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// An extra island being removed (its display was unplugged): stop following settings and displays.
    func teardown() {
        settingsObserver = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        isExpanded = false
    }
    /// `--tab=N` launch argument (0 lyrics, 1 office, 2 agents) — used for visual verification.
    public static var launchTab: Int = {
        for a in CommandLine.arguments where a.hasPrefix("--tab=") { return Int(a.dropFirst(6)) ?? 0 }
        return 0
    }()

    @Published public var notchWidth: CGFloat = 220
    @Published public var notchHeight: CGFloat = 38
    /// The physical notch as reported by macOS (no padding), and its horizontal offset from the screen center.
    @Published public var hasNotch: Bool = false
    /// The layout in use: true = attached to the notch (wings beside it, lyric rows hanging below), false = a floating
    /// capsule. Follows the "外觀" setting; in "自動" a notch narrower than 120pt (a camera hole-punch) is too small to
    /// put the cover and the bars beside, so the capsule is used.
    @Published public var notchStyle: Bool = false
    /// A capsule fused to the notch (see `IslandStyle.attached`). Implies a physical notch.
    @Published public var attached: Bool = false
    @Published public var realNotchSize: CGSize = CGSize(width: 220, height: 38)
    @Published public var realNotchDX: CGFloat = 0
    @Published public var compactWidth: CGFloat = 280
    /// The collapsed island shows a notice / timer / meeting (drawn at least 340 wide); the hit area follows it.
    public var wideBar = false
    /// A page the island should open on (set by things outside the view, e.g. a file drag reaching the notch).
    @Published var requestedTab: Int?
    @Published public var compactHeight: CGFloat = 66
    @Published public var expandedWidth: CGFloat = 572
    @Published public var baseExpandedHeight: CGFloat = 172
    /// A permission request opened for review (from the collapsed ✓): the island grows to show all of it.
    @Published var reviewingApproval: UUID?
    static let reviewExtra: CGFloat = 150
    public var expandedHeight: CGFloat { baseExpandedHeight + (reviewingApproval != nil ? Self.reviewExtra : 0) }
    /// The window is sized once for the tallest island, so it never resizes (only SwiftUI animates).
    var maxExpandedHeight: CGFloat { baseExpandedHeight + Self.reviewExtra }
    /// True while the pointer is on or just around the collapsed island (drives the "protrude" effect).
    @Published public var pointerNear: Bool = false
    @Published public var isExpanded: Bool = CommandLine.arguments.contains("--expanded")

    private var settingsObserver: AnyCancellable?

    init(screenID: CGDirectDisplayID? = nil) {
        self.screenID = screenID
        Self.all.add(self)
        updateDimensions()
        // Re-apply sizes whenever a preference changes (objectWillChange fires before the value is set).
        settingsObserver = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDimensions() }
        // A display was plugged in / removed, or its resolution changed: re-measure so the island follows.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateDimensions() }
    }

    private var screenObserver: NSObjectProtocol?

    /// The gear button: tucks the island away and opens the settings window.
    public func collapseAndShowSettings() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { isExpanded = false }
        SettingsWindowController.shared.show()
    }

    /// Idle island (nothing playing): on a notched display it stays in place, exactly as wide and tall as the notch
    /// so it is hidden behind it, and grows out of the notch by these amounts when the pointer comes near. The shape's
    /// 6pt shoulders mean a frame `rimWidth` wider than the notch has a body `rimWidth - 12` wider (10pt per side).
    public static let idleRimWidth: CGFloat = 32
    public static let idleRimHeight: CGFloat = 7.5
    /// The layout that wraps the notch (wings beside it, the top bar at notch height, lyric rows hanging below): the notch
    /// style, and the fused capsule, which is the same layout in a flat-topped rounded shape.
    public var integrated: Bool { notchStyle || attached }
    public var idleWidth: CGFloat { (notchStyle || attached) ? notchWidth : max(notchWidth, 120) }

    /// Swell when the pointer comes near: a notched island bulges down, the floating capsule grows a little all round.
    public var swellSize: CGSize { integrated ? CGSize(width: 24, height: 18) : CGSize(width: 16, height: 6) }
    /// Gap between the top of the screen and the island: none when attached to the notch; a capsule floats 6pt below
    /// the top edge, or 6pt below the menu bar on a notched display (so the physical notch never covers it).
    /// The fused capsule starts 4pt above the notch's lower edge, so it overlaps the notch with no gap between them.
    public var topInset: CGFloat { integrated ? 0 : (hasNotch ? notchHeight + 6 : 6) }
    /// The inset while idle: a fused capsule hides inside the notch (inset 0) and grows out of it from there.
    public func insetTop(idle: Bool) -> CGFloat { topInset }
    /// Height of the expanded island's top bar (tabs and buttons): only a notch makes it taller than it needs to be.
    public var topBarHeight: CGFloat { integrated ? notchHeight : 32 }
    /// Space between the island's edge and its content, the same on both sides. A notch-shaped island adds 6pt of
    /// shoulder at each side.
    public var contentEdge: CGFloat { integrated ? 22 : 16 }
    /// Extra room the (fixed-size) window keeps above the island for `topInset`.
    public static let windowExtraTop: CGFloat = 52
    /// Corner radius of the notch's lower edge (estimated by eye: Apple publishes no value). Used by the expanded fused island.
    public static let notchCorner: CGFloat = 12
    /// Width the collapsed lyric line can use (the capsule keeps the cover and the bars on the same line).
    public var compactLyricWidth: CGFloat { integrated ? compactWidth - 44 : compactWidth - 2 * NotchGeometry.capsuleSide }
    public static let capsuleSide: CGFloat = 40
    /// A little shorter than the notch, so the antialiased bottom edge never shows below it.
    public var idleHeight: CGFloat { notchHeight - 1.5 }

    public func updateDimensions() {
        let settings = AppSettings.shared
        let screen = self.screen

        let leftAux = screen.auxiliaryTopLeftArea
        let rightAux = screen.auxiliaryTopRightArea

        // `--simulate-no-notch` pretends the display has no notch (for checking the external-display look).
        let simulateNoNotch = CommandLine.arguments.contains("--simulate-no-notch")
        hasNotch = !simulateNoNotch && screen.safeAreaInsets.top > 0 && leftAux != nil && rightAux != nil
        if let left = leftAux, let right = rightAux, hasNotch {
            realNotchSize = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            realNotchDX = (left.maxX + right.minX) / 2 - screen.frame.midX
            notchWidth = realNotchSize.width                          // exact notch width, no padding
            notchHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 32)
        } else {
            // No physical notch (external display): a "virtual notch" only as tall as the menu bar and narrow,
            // so the island hangs from the top edge without a wide empty middle.
            realNotchDX = 0
            notchWidth = 120
            notchHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 30)
        }

        // The shape's concave shoulders inset the body by 6pt per side, so add 12pt to get a 36pt-wing body.
        // Without a notch the middle is narrow, so keep a minimum width that still fits a line of lyrics.
        switch settings.islandStyle {
        case .notch: notchStyle = true; attached = false
        case .capsule: notchStyle = false; attached = false
        case .attached: notchStyle = false; attached = hasNotch
        case .auto: notchStyle = false; attached = hasNotch && realNotchSize.width >= 120
        }
        compactWidth = notchStyle ? max(notchWidth + 72 + 12, 304) : (attached ? notchWidth + 90 : 290)
        let scale = CGFloat(settings.lyricFontScale)
        let translationOnOwnLine = settings.showTranslation && !settings.translationSideBySide
        // First line grows with the original size; a second line (translation / next lyric) with its own size.
        var lyricRows = 22 + (scale - 1) * 14
        if translationOnOwnLine { lyricRows += 16 + (scale - 1) * 14 }
        lyricRows = lyricRows.rounded()
        // Notch: the lyric rows hang below the notch. No notch: a floating capsule, like the iPhone's Dynamic Island,
        // with the cover, the lyric and the bars on one line.
        compactHeight = integrated ? notchHeight + lyricRows - (attached ? 4 : 0) : max(36, lyricRows + 14)
        // 540pt of content in both layouts: the notch shape adds a 6pt shoulder at each side (so +12pt of frame).
        // Only the notch layout reserves the notch's height for the top bar.
        expandedWidth = integrated ? 584 : 572
        baseExpandedHeight = integrated ? 178 : 172
    }
}
