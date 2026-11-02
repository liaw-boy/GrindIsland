import AppKit
import CoreAudio
import Foundation
import SwiftUI

/// Shows the output volume in the island while it changes, and the new output device when headphones connect or
/// disconnect (read-only: it listens to Core Audio, it never takes over the volume keys or hides the system's own indicator).
final class VolumeMonitor {
    static let shared = VolumeMonitor()
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastShown: (Float, Bool)?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue = DispatchQueue.main

    func start() {
        var defaultAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, queue) { [weak self] _, _ in
            self?.attach(announce: true)
        }
        attach(announce: false)
    }

    private func attach(announce: Bool) {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != device else { return }
        for (a, block) in deviceListeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(device, &a, queue, block)
        }
        deviceListeners = []
        device = id
        lastShown = read()
        // Built-in speakers have no main volume, only channels: listen on the main element, or on channel 1 without one.
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var a = Self.address(sel, scope: kAudioDevicePropertyScopeOutput)
            if !AudioObjectHasProperty(id, &a) { a.mElement = 1 }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed(on: id) }
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr { deviceListeners.append((a, block)) }
        }
        if announce, AppSettings.shared.volumeNotices, let name = Self.string(kAudioObjectPropertyName, of: id) {
            let transport = Self.transport(of: id)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else {
                NoticeCenter.shared.post(Self.deviceNotice(name: name, transport: transport), seconds: 4)
                return
            }
            // Earbuds: the model (for the right icon) and the charge come from the Bluetooth report a moment after
            // connecting. A model seen before is shown at once; a new one waits for the report instead of first
            // showing a guess from the name (which people rename).
            let known = Self.knownModels[name]
            let shown = Flag()
            if let pid = known {
                NoticeCenter.shared.post(Self.deviceNotice(name: name, transport: transport, battery: .init(productID: pid)), seconds: 4)
                shown.on = true
            }
            let connected = Date()
            func report(after delay: Double, last: Bool) {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                    let data = Self.bluetoothReport()
                    let pid = data.flatMap { Self.productID(json: $0, name: name) } ?? known
                    let b = data.flatMap { Self.budBattery(json: $0, name: name) }
                    DispatchQueue.main.async {
                        guard self?.device == id, Date().timeIntervalSince(connected) < 10 else { return }
                        if let pid = pid { Self.remember(name, pid) }
                        if let b = b {
                            NoticeCenter.shared.post(Self.deviceNotice(name: name, transport: transport, battery: b), seconds: 3.5)
                            shown.on = true
                        } else if !shown.on {
                            // No charge yet: show the model now (or the name guess when even that is unknown).
                            NoticeCenter.shared.post(Self.deviceNotice(name: name, transport: transport, battery: pid.map { .init(productID: $0) }), seconds: 4)
                            shown.on = true
                            if !last { report(after: 1.5, last: true) }
                        } else if !last { report(after: 1.5, last: true) }
                    }
                }
            }
            report(after: 0.4, last: false)
        }
    }

    private final class Flag { var on = false }

    /// Earbud models seen before, by device name (kept on this Mac only), so a reconnect shows the right icon at once.
    private static let modelsKey = "earbudModels"
    static var knownModels: [String: Int] { UserDefaults.standard.dictionary(forKey: modelsKey) as? [String: Int] ?? [:] }
    private static func remember(_ name: String, _ pid: Int) {
        var m = knownModels
        guard m[name] != pid, model(productID: pid) != nil else { return }
        m[name] = pid
        if m.count > 20 { m = Dictionary(uniqueKeysWithValues: m.prefix(20).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(m, forKey: modelsKey)
    }

    static func forgetModels() { UserDefaults.standard.removeObject(forKey: modelsKey) }

    /// The product ID of the connected device called `name` in the Bluetooth report (no charge needed).
    static func productID(json: Data, name: String) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'") }
        for dev in sections.flatMap({ ($0["device_connected"] as? [[String: Any]]) ?? [] }).flatMap({ $0 })
        where norm(dev.key) == norm(name) {
            if let s = (dev.value as? [String: Any])?["device_productID"] as? String { return Int(s.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        }
        return nil
    }

    struct BudBattery: Equatable {
        var left: Int?, right: Int?, case_: Int?, main: Int?
        /// Bluetooth product ID (Apple / Beats models), which tells the exact model whatever the device is called.
        var productID: Int? = nil

        init(left: Int? = nil, right: Int? = nil, case_: Int? = nil, main: Int? = nil, productID: Int? = nil) {
            self.left = left; self.right = right; self.case_ = case_; self.main = main; self.productID = productID
        }
        /// The lower earbud (what runs out first), or the single battery of headphones like AirPods Max.
        var buds: Int? { [left, right].compactMap { $0 }.min() ?? main }
    }

    /// Battery levels of the connected Bluetooth device called `name` in `system_profiler -json SPBluetoothDataType`
    /// output (falls back to the only connected device that reports earbud levels).
    static func budBattery(json: Data, name: String) -> BudBattery? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let devices = sections.flatMap { ($0["device_connected"] as? [[String: Any]]) ?? [] }.flatMap { $0 }
        func level(_ d: [String: Any], _ key: String) -> Int? {
            guard let s = d[key] as? String, let n = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))), (0...100).contains(n) else { return nil }
            return n
        }
        func battery(_ d: [String: Any]) -> BudBattery? {
            let pid = (d["device_productID"] as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
            let b = BudBattery(left: level(d, "device_batteryLevelLeft"), right: level(d, "device_batteryLevelRight"),
                               case_: level(d, "device_batteryLevelCase"), main: level(d, "device_batteryLevelMain"),
                               productID: pid)
            return b.buds == nil ? nil : b
        }
        // Names can differ in quote style between Core Audio and Bluetooth (’ vs ').
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'") }
        if let exact = devices.first(where: { norm($0.key) == norm(name) }), let b = (exact.value as? [String: Any]).flatMap(battery) { return b }
        // Otherwise only an unambiguous pair of earbuds (left/right levels): never a keyboard's or mouse's battery.
        let pods = devices.compactMap { ($0.value as? [String: Any]).flatMap(battery) }.filter { $0.left != nil || $0.right != nil }
        return pods.count == 1 ? pods[0] : nil
    }

    /// Runs the system's own report tool directly (no shell); nil if it fails or takes too long.
    static func bluetoothReport() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["-json", "-timeout", "5", "SPBluetoothDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && data.count < 2_000_000 ? data : nil
    }

    private func changed(on id: AudioObjectID) {
        guard id == device, let now = read() else { return }
        if let last = lastShown, last.0 == now.0, last.1 == now.1 { return }
        lastShown = now
        if AppSettings.shared.volumeNotices { NoticeCenter.shared.post(Self.notice(volume: now.0, muted: now.1), seconds: 1.6) }
    }

    /// Volume 0…1 and mute, from the main element (or the left channel on devices without one).
    private func read() -> (Float, Bool)? {
        func get<T>(_ sel: AudioObjectPropertySelector, element: UInt32, _ value: inout T) -> Bool {
            var a = Self.address(sel, scope: kAudioDevicePropertyScopeOutput, element: element)
            guard AudioObjectHasProperty(device, &a) else { return false }
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr
        }
        var vol: Float32 = 0
        guard get(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain, &vol)
                || get(kAudioDevicePropertyVolumeScalar, element: 1, &vol) else { return nil }
        var mute: UInt32 = 0
        _ = get(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, &mute)
        return (vol, mute != 0)
    }

    static func notice(volume: Float, muted: Bool) -> IslandNotice {
        let pct = muted ? 0 : Int((volume * 100).rounded())
        // One symbol whose waves fill with the level (its variable value), so the speaker never moves sideways.
        let icon = pct == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        return IslandNotice(icon: icon, tint: .white, title: "音量", detail: muted ? "靜音" : "\(pct)%",
                            trailing: "\(pct)", meter: Double(pct) / 100)
    }

    /// "AirPods Pro 已連線" / "MacBook Pro 喇叭": the device name comes from the device itself, so it is only shown, trimmed.
    static func deviceNotice(name: String, transport: UInt32, battery: BudBattery? = nil) -> IslandNotice {
        let shown = String(name.replacingOccurrences(of: "\n", with: " ").prefix(40))
        let lower = shown.lowercased()
        let icon: String
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: icon = "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: icon = "tv"
        case kAudioDeviceTransportTypeAirPlay: icon = "airplayaudio"
        default:
            // The model from its product ID when known; otherwise a guess from the name (which people rename).
            icon = battery?.productID.flatMap { model(productID: $0)?.icon }
                ?? (lower.contains("airpods max") ? "airpods.max" : lower.contains("airpods pro") ? "airpods.pro"
                    : lower.contains("airpods") ? "airpods" : lower.contains("beats") ? "beats.headphones" : "headphones")
        }
        let builtIn = transport == kAudioDeviceTransportTypeBuiltIn
        // Only one earbud out (the other in the case or away): say which, with that side's own icon.
        let side: String? = battery.flatMap { b in b.left != nil && b.right == nil ? "left" : b.right != nil && b.left == nil ? "right" : nil }
        let budsLabel = side == "left" ? "左耳" : side == "right" ? "右耳" : "耳機"
        let levels = [battery?.buds.map { "\(budsLabel) \($0)%" }, battery?.case_.map { "盒 \($0)%" }].compactMap { $0 }
        var n = IslandNotice(icon: icon, tint: .white, title: builtIn ? "輸出" : "已連線",
                             detail: ([shown] + levels).joined(separator: " · "),
                             trailing: builtIn ? "喇叭" : battery?.buds.map { "\($0)%" } ?? "✓")
        let wireless = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        if wireless && icon != "headphones" {
            let caseIcon = battery?.productID.flatMap { model(productID: $0)?.caseIcon }
                ?? (icon == "airpods.pro" ? "airpods.pro.chargingcase.wireless.fill" : "airpods.chargingcase.fill")
            n.icon = side.map { symbol(Self.singleIcon(icon, side: $0), else: icon) } ?? symbol(icon, else: "headphones")
            if n.icon == icon { n.icon = symbol(icon, else: "headphones") }
            n.earbuds = .init(buds: battery?.buds, caseLevel: battery?.case_, caseIcon: symbol(caseIcon, else: "airpods.chargingcase.fill"))
        }
        return n
    }

    /// Apple / Beats Bluetooth product IDs → the system's own symbols for that model and its case.
    /// shortcut: IDs from public lists of these devices; an unknown one falls back to the name guess. Add new models here.
    static func model(productID: Int) -> (icon: String, caseIcon: String?)? {
        switch productID {
        case 0x2002: return ("airpods", "airpods.chargingcase.fill")                              // AirPods (1st gen)
        case 0x200F: return ("airpods", "airpods.chargingcase.wireless.fill")                     // AirPods (2nd gen)
        case 0x2013: return ("airpods.gen3", "airpods.gen3.chargingcase.wireless.fill")           // AirPods (3rd gen)
        case 0x2019, 0x201B: return ("airpods.gen4", "airpods.gen4.chargingcase.wireless.fill")   // AirPods 4
        case 0x200E, 0x2014, 0x2024: return ("airpods.pro", "airpods.pro.chargingcase.wireless.fill")  // AirPods Pro / Pro 2
        case 0x200A, 0x201F: return ("airpods.max", nil)                                          // AirPods Max
        case 0x200B: return ("beats.powerbeats.pro", "beats.powerbeats.pro.chargingcase.fill")
        case 0x2011: return ("beats.studiobuds", "beats.studiobuds.chargingcase.fill")
        case 0x2016: return ("beats.studiobudsplus", "beats.studiobudsplus.chargingcase.fill")
        case 0x2012: return ("beats.fitpro", "beats.fitpro.chargingcase.fill")
        case 0x2003, 0x2006: return ("beats.powerbeats3", nil)
        case 0x2009, 0x200C, 0x2017: return ("beats.headphones", nil)
        default: return nil
        }
    }

    /// One earbud of a pair's symbol: "airpods.gen3" → "airpod.gen3.left", "airpods.pro" → "airpodpro.left",
    /// Beats → "<name>.left".
    static func singleIcon(_ pair: String, side: String) -> String {
        if pair == "airpods.pro" { return "airpodpro.\(side)" }
        if pair.hasPrefix("airpods") { return "airpod" + pair.dropFirst("airpods".count) + ".\(side)" }
        return "\(pair).\(side)"
    }

    /// `name` if this macOS has that symbol (newer models' symbols are missing on older systems), else `fallback`.
    static func symbol(_ name: String, else fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }

    private static func transport(of id: AudioObjectID) -> UInt32 {
        var a = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t) == noErr ? t : 0
    }

    private static func string(_ sel: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var a = address(sel, scope: kAudioObjectPropertyScopeGlobal)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
        return v as String
    }

    private static func address(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }
}
