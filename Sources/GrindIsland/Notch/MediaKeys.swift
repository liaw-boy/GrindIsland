import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

/// Optional (設定 › 提示): the volume, brightness and keyboard-light keys are handled here instead of by macOS, so
/// only the island shows the level and the system's own on-screen indicator does not appear.
/// Needs Accessibility permission (an event tap). Whenever we cannot apply a key ourselves (no permission, a device
/// without volume control, a private call missing on this macOS), the key goes to macOS as usual.
final class MediaKeys {
    static let shared = MediaKeys()

    enum Key: Hashable { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown, lightUp, lightDown }

    private var tap: CFMachPort?
    private var handled = Set<Key>()
    private var source: CFRunLoopSource?
    private var waitTimer: Timer?

    /// 16 steps like macOS; with ⌥⇧ held, quarter steps.
    static let step: Float = 1.0 / 16

    var trusted: Bool { AXIsProcessTrusted() }

    /// Follows the setting: starts the tap (asking for permission once if needed), or removes it.
    func apply(enabled: Bool) {
        if !enabled { stop(); return }
        guard tap == nil else { return }
        if trusted { start(); return }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        // Start as soon as permission is granted in System Settings.
        waitTimer?.invalidate()
        waitTimer = Timer.commonModeTimer(interval: 2, repeats: true) { [weak self] t in
            guard let self = self, AppSettings.shared.takeOverMediaKeys else { t.invalidate(); return }
            if self.trusted { t.invalidate(); self.start() }
        }
    }

    private func start() {
        let mask = CGEventMask(1) << 14   // NX_SYSDEFINED: media / special keys
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MediaKeys.shared.handle(type: type, event: event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stop() {
        waitTimer?.invalidate()
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns a slow tap off; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
              let (key, down) = Self.decode(data1: ns.data1) else { return Unmanaged.passUnretained(event) }
        // A key-up is ours only if we took its key-down; one we handed to macOS must reach it too, or the key sticks.
        guard down else { return handled.remove(key) != nil ? nil : Unmanaged.passUnretained(event) }
        let fine = ns.modifierFlags.contains([.option, .shift])
        if perform(key, fine: fine) { handled.insert(key); return nil }
        return Unmanaged.passUnretained(event)
    }

    /// NX_SYSDEFINED data1: key code in the high 16 bits, key state (0xA down, 0xB up) in bits 8–15.
    static func decode(data1: Int) -> (Key, down: Bool)? {
        let code = (data1 & 0xFFFF0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        let key: Key
        switch code {
        case 0: key = .volumeUp            // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown          // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute                // NX_KEYTYPE_MUTE
        case 2: key = .brightnessUp        // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown      // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 21: key = .lightUp            // NX_KEYTYPE_ILLUMINATION_UP
        case 22: key = .lightDown          // NX_KEYTYPE_ILLUMINATION_DOWN
        default: return nil
        }
        return (key, state == 0xA)
    }

    /// The next level: one step (or a quarter) toward up/down, landing on the step grid, clamped to 0…1.
    static func next(_ level: Float, up: Bool, fine: Bool) -> Float {
        let s = fine ? step / 4 : step
        let snapped = (level / s).rounded()
        return min(max((snapped + (up ? 1 : -1)) * s, 0), 1)
    }

    /// Applies the key; false when it could not (then macOS handles it).
    private func perform(_ key: Key, fine: Bool) -> Bool {
        switch key {
        case .volumeUp, .volumeDown:
            guard let dev = Audio.defaultOutput(), let v = Audio.volume(dev) else { return false }
            let up = key == .volumeUp
            if Audio.muted(dev) == true { _ = Audio.setMuted(dev, false) }
            let nv = Self.next(v, up: up, fine: fine)
            guard Audio.setVolume(dev, nv) else { return false }
            // Our own change: show it here (setting the virtual main volume does not reach the volume listener).
            NoticeCenter.shared.post(VolumeMonitor.notice(volume: nv, muted: false), seconds: 1.6)
            return true
        case .mute:
            guard let dev = Audio.defaultOutput(), let m = Audio.muted(dev) else { return false }
            guard Audio.setMuted(dev, !m) else { return false }
            NoticeCenter.shared.post(VolumeMonitor.notice(volume: Audio.volume(dev) ?? 0, muted: !m), seconds: 1.6)
            return true
        case .brightnessUp, .brightnessDown:
            guard let b = BrightnessMonitor.shared.displayLevel() else { return false }
            let v = Self.next(b, up: key == .brightnessUp, fine: fine)
            guard BrightnessMonitor.shared.setDisplay(v) else { return false }
            NoticeCenter.shared.post(BrightnessMonitor.notice(level: v, keyboard: false), seconds: 1.6)
            return true
        case .lightUp, .lightDown:
            guard let b = BrightnessMonitor.shared.keyboardLevel() else { return false }
            let v = Self.next(b, up: key == .lightUp, fine: fine)
            guard BrightnessMonitor.shared.setKeyboard(v) else { return false }
            NoticeCenter.shared.post(BrightnessMonitor.notice(level: v, keyboard: true), seconds: 1.6)
            return true
        }
    }

    /// The default output's volume through the system's virtual main volume (all channels together).
    enum Audio {
        static func defaultOutput() -> AudioObjectID? {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var id = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr
                && id != kAudioObjectUnknown ? id : nil
        }

        private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        }

        static func volume(_ dev: AudioObjectID) -> Float? {
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectHasProperty(dev, &a) && AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
        }

        static func setVolume(_ dev: AudioObjectID, _ value: Float) -> Bool {
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
            var v = Float32(value)
            return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        }

        static func muted(_ dev: AudioObjectID) -> Bool? {
            var a = address(kAudioDevicePropertyMute)
            var m: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectHasProperty(dev, &a) && AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &m) == noErr ? m != 0 : nil
        }

        static func setMuted(_ dev: AudioObjectID, _ on: Bool) -> Bool {
            var a = address(kAudioDevicePropertyMute)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
            var m: UInt32 = on ? 1 : 0
            return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
        }
    }
}
