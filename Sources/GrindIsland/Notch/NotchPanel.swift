import AppKit
import SwiftUI
import Combine

public final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// The island this view draws (its own display's sizes).
    var geom: NotchGeometry = .shared

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // The panel never becomes key, so AppKit does not manage the cursor over it, and the window underneath kept
    // showing its own (a resize arrow at its edge). Over the island itself the cursor is the plain arrow; over the
    // transparent margin the window underneath keeps its cursor.
    private var cursorArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = cursorArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        cursorArea = a
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if hitTest(convert(event.locationInWindow, from: nil)) != nil { NSCursor.arrow.set() }
    }

    public override func cursorUpdate(with event: NSEvent) {
        if hitTest(convert(event.locationInWindow, from: nil)) != nil { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let idle = !IslandPresence.shared.isActive && !geom.isExpanded
        // A hidden island must not swallow clicks meant for the menu bar (unless its rim is showing).
        if idle && !geom.pointerNear { return nil }
        // Hit area = exactly what is drawn (the swell only while it is swollen), so nothing around the island
        // swallows clicks meant for what is underneath (e.g. a browser tab's close button).
        let compactW = geom.wideBar ? max(340, geom.compactWidth) : geom.compactWidth
        let currentW = geom.isExpanded ? geom.expandedWidth
            : (idle ? geom.idleWidth + NotchGeometry.idleRimWidth : compactW + (geom.pointerNear ? geom.swellSize.width : 0))
        let currentH = geom.isExpanded ? geom.expandedHeight
            : (idle ? geom.idleHeight + NotchGeometry.idleRimHeight : geom.compactHeight + (geom.pointerNear ? geom.swellSize.height : 0))

        let activeX = (bounds.width - currentW) / 2
        let activeY = bounds.height - currentH - geom.insetTop(idle: idle) // AppKit coordinates: bottom is 0, top is bounds.height
        let activeRect = CGRect(x: activeX, y: activeY, width: currentW, height: currentH)

        if activeRect.contains(point) {
            return super.hitTest(point)
        }
        return nil
    }
}

public final class NotchPanel: NSPanel {
    /// The main island; `syncExtraPanels()` adds one per other display when "顯示在" is "所有螢幕".
    public static let shared = NotchPanel(geometry: .shared)
    let geom: NotchGeometry

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var scrollMonitor: Any?
    private var swipe = SwipeSkip()

    init(geometry: NotchGeometry) {
        self.geom = geometry
        let geom = geometry
        let screen = geometry.screen

        // Window is larger than the expanded island so the spring can overshoot without being clipped.
        let maxW = geom.expandedWidth + Self.overshootW
        let maxH = geom.maxExpandedHeight + Self.overshootH + NotchGeometry.windowExtraTop
        let x = screen.frame.midX - (maxW / 2)
        let y = screen.frame.maxY - maxH
        let rect = NSRect(x: x, y: y, width: maxW, height: maxH)

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = false
        self.level = NSWindow.Level(rawValue: 28) // above other notch apps (e.g. Dynamic Lyrics 2 uses 27)
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovable = false
        self.hidesOnDeactivate = false

        _ = CursorAccess.allowInBackground
        let host = NotchHostingView(rootView: NotchRootView().environmentObject(geom))
        host.geom = geom
        self.contentView = host

        setupEventMonitors()

        // Re-apply screen / visibility when a preference changes, and poll for fullscreen apps.
        settingsObserver = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyPlacement()
                    self?.applyVisibility()
                }
            }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Let NotchGeometry re-measure first, then move the window to the (possibly different) target screen.
            DispatchQueue.main.async { self?.applyPlacement(); self?.applyVisibility() }
        }
        // A fullscreen app hides the menu bar, so the island steps aside too.
        fullscreenTimer = Timer.commonModeTimer(interval: 1.0, repeats: true) { [weak self] _ in
            self?.applyVisibility()
        }
        // While expanded, watch the pointer; once it has stayed away for a few seconds the island collapses.
        expansionObserver = geom.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in self?.watchPointer(whileExpanded: expanded) }
    }

    private var expansionObserver: AnyCancellable?
    private var collapseTimer: Timer?
    private var outsideSince: Date?
    /// Seconds the pointer may stay outside the expanded island before it collapses: short once the pointer has
    /// been on the island (it collapses as you leave), longer if it never was (opened from the menu, say).
    private let collapseDelayAfterLeaving: TimeInterval = 0.35
    private let collapseDelayIfNeverEntered: TimeInterval = 2.5
    private var pointerEntered = false
    /// A menu opened from the island (Taildrop targets, a file's context menu) sits outside it: while it is open the
    /// pointer is on the menu, not "gone", so the island stays.
    private var menuOpen = false
    private var menuObservers: [NSObjectProtocol] = []

    private func watchPointer(whileExpanded expanded: Bool) {
        DispatchQueue.main.async { HotKeys.shared.updateOpenKeys() }   // after the new value is set (this runs on willSet)
        collapseTimer?.invalidate()
        collapseTimer = nil
        outsideSince = nil
        pointerEntered = false
        // `--expanded` (used for screenshots) keeps the island open.
        guard expanded, !CommandLine.arguments.contains("--expanded") else { return }
        collapseTimer = Timer.commonModeTimer(interval: 0.1, repeats: true) { [weak self] _ in
            self?.checkAutoCollapse()
        }
    }

    private func checkAutoCollapse() {
        if menuOpen { outsideSince = nil; return }
        let screen = geom.screen
        let slack: CGFloat = 4
        let island = CGRect(x: screen.frame.midX - geom.expandedWidth / 2 - slack,
                            y: screen.frame.maxY - geom.topInset - geom.expandedHeight - slack,
                            width: geom.expandedWidth + 2 * slack, height: geom.expandedHeight + 2 * slack)
        if island.contains(NSEvent.mouseLocation) { pointerEntered = true; outsideSince = nil; return }

        let since = outsideSince ?? Date()
        outsideSince = since
        let delay = pointerEntered ? collapseDelayAfterLeaving : collapseDelayIfNeverEntered
        if Date().timeIntervalSince(since) >= delay {
            outsideSince = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { geom.isExpanded = false }
        }
    }

    static let overshootW: CGFloat = 48
    static let overshootH: CGFloat = 24

    private var settingsObserver: AnyCancellable?
    private var fullscreenTimer: Timer?
    private var screenChangeObserver: NSObjectProtocol?

    /// Keeps the window centered at the top of the chosen display.
    func applyPlacement() {
        let screen = geom.screen
        let w = geom.expandedWidth + Self.overshootW
        let h = geom.maxExpandedHeight + Self.overshootH + NotchGeometry.windowExtraTop
        let rect = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        if rect != frame { setFrame(rect, display: false) }
    }

    func applyVisibility() {
        let settings = AppSettings.shared
        let hide = Self.fullscreenAppActive(on: geom.screen)
        if hide {
            if isVisible { orderOut(nil) }
        } else if !isVisible {
            orderFrontRegardless()
        }
    }

    /// True when another app has a normal-layer window covering the whole display (a fullscreen Space).
    private static func fullscreenAppActive(on screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return false }
        let target = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            if abs(bounds.minX - target.minX) < 2, abs(bounds.minY - target.minY) < 2,
               abs(bounds.width - target.width) < 2, abs(bounds.height - target.height) < 2 {
                return true
            }
        }
        return false
    }

    /// Pointer proximity: true when the pointer is on, or within ~20pt of, the island (works even when the
    /// pointer is outside our click-through area, so the island can react as you approach the notch).
    private func updatePointerProximity() {
        let m = CGFloat(AppSettings.shared.edgeSensitivity)
        if !IslandPresence.shared.isActive && !geom.isExpanded {
            // Hidden: a rim swells out around the notch when the pointer comes close to it.
            let screen = geom.screen
            let nw = geom.idleWidth
            let side = NotchGeometry.idleRimWidth / 2 + m
            let below = geom.insetTop(idle: true) + geom.notchHeight + NotchGeometry.idleRimHeight + m
            let zone = CGRect(x: screen.frame.midX - nw / 2 - side, y: screen.frame.maxY - below,
                              width: nw + 2 * side, height: below + 4)
            let near = zone.contains(NSEvent.mouseLocation)
            if near != geom.pointerNear { geom.pointerNear = near }
            return
        }
        let screen = geom.screen
        let compactW = geom.wideBar ? max(340, geom.compactWidth) : geom.compactWidth
        let w = geom.isExpanded ? geom.expandedWidth : compactW
        let h = geom.isExpanded ? geom.expandedHeight : geom.compactHeight
        let rect = CGRect(x: screen.frame.midX - w / 2 - m, y: screen.frame.maxY - geom.topInset - h - m,
                          width: w + 2 * m, height: h + geom.topInset + m + 4)   // extends above the screen edge too
        let near = rect.contains(NSEvent.mouseLocation)
        if near != geom.pointerNear { geom.pointerNear = near }
    }

    /// Keyboard input is off (clicking the island never steals typing from other apps), except while a text form
    /// on the island needs it (e.g. a new calendar event).
    public var acceptsKeyboard = false {
        didSet {
            if acceptsKeyboard { makeKeyAndOrderFront(nil) } else if isKeyWindow { resignKey() }
        }
    }
    public override var canBecomeKey: Bool { acceptsKeyboard }

    /// The add-event form needs typing: the open island (the one the form is on) takes the keyboard while it shows.
    static func acceptKeyboard(_ on: Bool) {
        for p in all where on ? p.geom.isExpanded : p.acceptsKeyboard { p.acceptsKeyboard = on }
    }

    /// The main island plus one per other display when "顯示在" is "所有螢幕".
    static var all: [NotchPanel] { [shared] + extras.values }
    private static var extras: [CGDirectDisplayID: NotchPanel] = [:]

    /// Adds / removes the extra islands to match the setting and the displays plugged in.
    static func syncExtraPanels() {
        let main = NotchGeometry.displayID(of: shared.geom.screen)
        let wanted: Set<CGDirectDisplayID> = AppSettings.shared.targetScreenName == AppSettings.allScreens
            ? Set(NSScreen.screens.compactMap(NotchGeometry.displayID)).subtracting(main.map { [$0] } ?? []) : []
        for (id, p) in extras where !wanted.contains(id) {
            p.teardown()
            extras[id] = nil
        }
        for id in wanted where extras[id] == nil {
            let p = NotchPanel(geometry: NotchGeometry(screenID: id))
            extras[id] = p
            p.applyVisibility()
        }
    }

    /// An extra island going away: stop its timers, observers and monitors (and release the open-island keys).
    func teardown() {
        orderOut(nil)
        geom.teardown()
        fullscreenTimer?.invalidate(); fullscreenTimer = nil
        collapseTimer?.invalidate(); collapseTimer = nil
        settingsObserver = nil
        expansionObserver = nil
        if let o = screenChangeObserver { NotificationCenter.default.removeObserver(o) }
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []
        for m in [globalMoveMonitor, localMoveMonitor, globalMouseMonitor, localMouseMonitor, scrollMonitor, globalDragMonitor] {
            if let m = m { NSEvent.removeMonitor(m) }
        }
        globalMoveMonitor = nil; localMoveMonitor = nil; globalMouseMonitor = nil
        localMouseMonitor = nil; scrollMonitor = nil; globalDragMonitor = nil
        HotKeys.shared.updateOpenKeys()
    }

    private var globalDragMonitor: Any?
    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    private func watchFileDrag(_ event: NSEvent) {
        let pb = NSPasteboard(name: .drag)
        if event.type == .leftMouseDown { dragBaseline = pb.changeCount; return }
        guard pb.changeCount != dragBaseline, pb.types?.contains(.fileURL) == true,
              !AppSettings.shared.hiddenTabs.contains(Self.shelfTab) else { return }   // shelf turned off in settings
        let screen = geom.screen
        // Near the notch; when the island is open on another page, anywhere over it.
        let h: CGFloat = geom.isExpanded ? geom.topInset + geom.expandedHeight + 4 : 64
        let zone = CGRect(x: screen.frame.midX - geom.expandedWidth / 2, y: screen.frame.maxY - h, width: geom.expandedWidth, height: h)
        guard zone.contains(NSEvent.mouseLocation) else { return }
        dragBaseline = pb.changeCount   // once per drag
        geom.requestedTab = Self.shelfTab
        if !geom.isExpanded {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            withAnimation(.spring(response: 0.46, dampingFraction: 0.68)) { geom.isExpanded = true }
        }
    }
    static let shelfTab = 4

    private func setupEventMonitors() {
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            DispatchQueue.main.async { self?.updatePointerProximity() }
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updatePointerProximity()
            return event
        }

        // Close on outside click
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.geom.isExpanded,
                  !CommandLine.arguments.contains("--expanded") else { return }
            let mouseLoc = NSEvent.mouseLocation
            if !self.frame.contains(mouseLoc) {
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        self.geom.isExpanded = false
                    }
                }
            }
        }

        menuObservers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.menuOpen = name == NSMenu.didBeginTrackingNotification
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Only clicks in the island's own window: a click on one of its menus is not "outside".
            guard let self = self, event.window === self, self.geom.isExpanded,
                  !CommandLine.arguments.contains("--expanded") else { return event }
            let windowPoint = event.locationInWindow
                let currentW = geom.expandedWidth
            let currentH = geom.expandedHeight
            guard let cv = self.contentView else { return event }
            let activeX = (cv.bounds.width - currentW) / 2
            let activeY = cv.bounds.height - currentH
            let activeRect = CGRect(x: activeX, y: activeY, width: currentW, height: currentH)

            if !activeRect.contains(windowPoint) {
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        self.geom.isExpanded = false
                    }
                }
            }
            return event
        }

        // A file drag reaching the notch opens the island on the shelf page, so the file can be dropped there.
        // The drag pasteboard keeps old contents, so only a drag that started after the last mouse-down counts.
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            DispatchQueue.main.async { self?.watchFileDrag(event) }
        }

        // Two-finger horizontal swipe on the collapsed island skips tracks (trackpad gestures only, not wheel mice).
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self = self else { return event }
            if event.phase == .began { self.swipe.begin() }   // reset even if this gesture is ignored, so no stale travel carries over
            guard event.window === self, event.hasPreciseScrollingDeltas,
                  !self.geom.isExpanded, MusicTracker.shared.isPlaying else { return event }
            // Natural scrolling reports deltas in the fingers' direction; otherwise they are reversed.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            switch event.phase {
            case .changed: self.swipe.add(fingerDX: sign * event.scrollingDeltaX, fingerDY: sign * event.scrollingDeltaY)
            case .ended:
                switch self.swipe.end() {
                case .next?: MusicTracker.shared.nextTrack()
                case .previous?: MusicTracker.shared.previousTrack()
                case nil: return event
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                self.swipe.begin()
            default: break
            }
            return event
        }
    }

    deinit {
        if let g = globalMoveMonitor { NSEvent.removeMonitor(g) }
        if let l = localMoveMonitor { NSEvent.removeMonitor(l) }
        if let g = globalMouseMonitor { NSEvent.removeMonitor(g) }
        if let l = localMouseMonitor { NSEvent.removeMonitor(l) }
        if let s = scrollMonitor { NSEvent.removeMonitor(s) }
    }
}

enum CursorAccess {
    /// macOS only lets the active app set the cursor, and the island never becomes active (it would take the
    /// keyboard from what you are typing in). This connection property, used by window tools, lets a background app
    /// set it too. Not public API: if it is missing, the cursor simply behaves as before.
    static let allowInBackground: Void = {
        typealias Conn = @convention(c) () -> Int32
        typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let c = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
              let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(c, to: Conn.self)()
        _ = unsafeBitCast(s, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }()
}
