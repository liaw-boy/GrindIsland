import AppKit
import Carbon
import SwiftUI

/// Keyboard shortcuts (system hot keys: no permission needed).
/// - The open/close shortcut (設定 › 一般 › 快捷鍵) toggles the island on the display under the pointer.
/// - Only while an island is open: ⌥1…⌥7 pick a page and Esc closes it. They are released as soon as it closes, so
///   other apps keep ⌥1 and Esc the rest of the time.
final class HotKeys {
    static let shared = HotKeys()

    /// Choices for the open/close shortcut: setting value → (label, key code, Carbon modifiers).
    static let choices: [(id: String, label: String, key: UInt32, mods: UInt32)] = [
        ("ctrl-opt-space", "⌃⌥ Space", UInt32(kVK_Space), UInt32(controlKey | optionKey)),
        ("opt-space", "⌥ Space", UInt32(kVK_Space), UInt32(optionKey)),
        ("off", "關閉", 0, 0),
    ]

    private enum ID: UInt32 { case toggle = 1, close = 2, tab0 = 10 }
    private static let tabKeys: [UInt32] = [UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4),
                                            UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_7)]

    private var toggleRef: EventHotKeyRef?
    private var openRefs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Registers the open/close shortcut from the setting (call again when it changes).
    func apply(_ choice: String) {
        installHandler()
        if let r = toggleRef { UnregisterEventHotKey(r); toggleRef = nil }
        guard let c = Self.choices.first(where: { $0.id == choice }), c.id != "off" else { return }
        toggleRef = register(ID.toggle.rawValue, key: c.key, mods: c.mods)
    }

    /// The page / Esc keys exist only while some island is open.
    func updateOpenKeys() {
        let open = NotchGeometry.anyExpanded
        if open, openRefs.isEmpty {
            installHandler()
            openRefs = Self.tabKeys.enumerated().compactMap { i, k in register(ID.tab0.rawValue + UInt32(i), key: k, mods: UInt32(optionKey)) }
            if let esc = register(ID.close.rawValue, key: UInt32(kVK_Escape), mods: 0) { openRefs.append(esc) }
        } else if !open, !openRefs.isEmpty {
            openRefs.forEach { UnregisterEventHotKey($0) }
            openRefs = []
        }
    }

    private func register(_ id: UInt32, key: UInt32, mods: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4752_4E44), id: id)   // 'GRND'
        let st = RegisterEventHotKey(key, mods, hid, GetApplicationEventTarget(), 0, &ref)
        return st == noErr ? ref : nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hid = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hid)
            DispatchQueue.main.async { HotKeys.shared.pressed(hid.id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// The island the keys act on: the open one, else the one on the display under the pointer.
    private var target: NotchGeometry {
        if let open = NotchGeometry.all.allObjects.first(where: { $0.isExpanded }) { return open }
        let mouse = NSEvent.mouseLocation
        return NotchGeometry.all.allObjects.first { $0.screen.frame.contains(mouse) } ?? .shared
    }

    private func pressed(_ id: UInt32) {
        let g = target
        switch id {
        case ID.toggle.rawValue:
            withAnimation(.spring(response: 0.46, dampingFraction: 0.72)) { g.isExpanded.toggle() }
        case ID.close.rawValue:
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { g.isExpanded = false }
        case ID.tab0.rawValue..<(ID.tab0.rawValue + UInt32(Self.tabKeys.count)):
            // ⌥n is the n-th page as shown (pages turned off in settings are skipped).
            let shown = NotchRootView.tabs.map(\.id).filter { !AppSettings.shared.hiddenTabs.contains($0) }
            let n = Int(id - ID.tab0.rawValue)
            if n < shown.count { g.requestedTab = shown[n] }
        default: break
        }
    }
}
