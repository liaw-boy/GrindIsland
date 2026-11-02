import AppKit
import CoreGraphics
import Foundation

/// Shows display and keyboard-backlight brightness in the island while you change them (keys or Control Center),
/// like the volume. Read-only. macOS has no public API or change notification for either, so this samples the
/// system's own private readers (DisplayServices, CoreBrightness); if they are missing it simply shows nothing.
final class BrightnessMonitor {
    static let shared = BrightnessMonitor()

    private var timer: Timer?
    private var display: Float?
    private var keyboard: Float?
    private var getDisplay: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32)?
    private var setDisplayFn: (@convention(c) (UInt32, Float) -> Int32)?
    private var kbClient: NSObject?
    private var kbID: UInt64 = 0
    private var displayID = CGMainDisplayID()

    func start() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
           let f = dlsym(h, "DisplayServicesGetBrightness") {
            getDisplay = unsafeBitCast(f, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
            if let g = dlsym(h, "DisplayServicesSetBrightness") {
                setDisplayFn = unsafeBitCast(g, to: (@convention(c) (UInt32, Float) -> Int32).self)
            }
        }
        if dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
           let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let c = cls.init()
            let ids = c.responds(to: Self.idsSel) ? (c.perform(Self.idsSel)?.takeRetainedValue() as? [NSNumber]) ?? [] : []
            if let id = ids.first, c.responds(to: Self.kbSel) { kbClient = c; kbID = id.uint64Value }
        }
        guard getDisplay != nil || kbClient != nil else { return }
        displayID = Self.builtInDisplay()
        display = readDisplay()
        keyboard = readKeyboard()
        // shortcut: sampling 5×/s (two tiny reads); switch to a change callback if a public one ever appears.
        timer = Timer.commonModeTimer(interval: 0.2, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
        if let now = readDisplay() {
            if let old = display, Self.isUserChange(old: old, new: now, secondsSinceInput: idle), AppSettings.shared.volumeNotices {
                NoticeCenter.shared.post(Self.notice(level: now, keyboard: false), seconds: 1.6)
            }
            display = now
        }
        if let now = readKeyboard() {
            if let old = keyboard, Self.isUserChange(old: old, new: now, secondsSinceInput: idle), AppSettings.shared.volumeNotices {
                NoticeCenter.shared.post(Self.notice(level: now, keyboard: true), seconds: 1.6)
            }
            keyboard = now
        }
    }

    // MARK: Used by MediaKeys (the brightness keys handled by us)

    func displayLevel() -> Float? { readDisplay() }
    func keyboardLevel() -> Float? { readKeyboard() }

    func setDisplay(_ v: Float) -> Bool {
        guard let set = setDisplayFn, set(displayID, v) == 0 else { return false }
        display = v   // our own change: no second notice from sampling
        return true
    }

    func setKeyboard(_ v: Float) -> Bool {
        guard let c = kbClient, c.responds(to: Self.kbSetSel), let m = c.method(for: Self.kbSetSel) else { return false }
        typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        guard unsafeBitCast(m, to: Set.self)(c, Self.kbSetSel, v, kbID) else { return false }
        keyboard = v
        return true
    }

    /// A key press or a Control Center slider moves the level in clear steps right after some input; automatic
    /// brightness (ambient light) and the backlight's idle fade drift without any. Only the former is shown.
    static func isUserChange(old: Float, new: Float, secondsSinceInput: Double) -> Bool {
        abs(new - old) >= 0.02 && secondsSinceInput < 1.0
    }

    static func notice(level: Float, keyboard: Bool) -> IslandNotice {
        let pct = Int((min(max(level, 0), 1) * 100).rounded())
        let icon = keyboard ? (pct == 0 ? "light.min" : "light.max") : "sun.max.fill"
        return IslandNotice(icon: icon, tint: .white, title: keyboard ? "鍵盤亮度" : "螢幕亮度", detail: "\(pct)%",
                            trailing: "\(pct)", meter: Double(pct) / 100)
    }

    private func readDisplay() -> Float? {
        guard let get = getDisplay else { return nil }
        var b: Float = 0
        if get(displayID, &b) == 0 { return b }
        displayID = Self.builtInDisplay()   // displays changed: look it up again next time
        return nil
    }

    private func readKeyboard() -> Float? {
        guard let c = kbClient, let m = c.method(for: Self.kbSel) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(m, to: Get.self)(c, Self.kbSel, kbID)
    }

    private static func builtInDisplay() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    /// kCGAnyInputEventType (~0), which CGEventType has no case for.
    private static let anyInput = unsafeBitCast(UInt32.max, to: CGEventType.self)
    private static let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
    private static let kbSel = NSSelectorFromString("brightnessForKeyboard:")
    private static let kbSetSel = NSSelectorFromString("setBrightness:forKeyboard:")
}
