import Foundation
import IOKit.ps
import SwiftUI

/// Posts an island notice when the charger is plugged in and when the battery runs low. Read-only: it only listens
/// to the system's power-source notifications.
final class BatteryMonitor {
    static let shared = BatteryMonitor()

    struct Reading: Equatable {
        var percent: Int
        var onAC: Bool
    }

    static let lowLevels = [20, 10]
    private var last: Reading?
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        last = Self.read()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().changed()
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
    }

    private func changed() {
        guard let now = Self.read() else { return }
        BatteryStatus.shared.refresh()
        if AppSettings.shared.batteryNotices, let n = Self.notice(from: last, to: now) { NoticeCenter.shared.post(n) }
        last = now
    }

    /// The internal battery, or nil on a Mac without one.
    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Reading(percent: cur * 100 / max, onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    /// What changed worth telling: the charger was just connected, or the level fell to a low mark on battery.
    static func notice(from old: Reading?, to new: Reading) -> IslandNotice? {
        guard let old = old else { return nil }
        if new.onAC && !old.onAC {
            return IslandNotice(icon: "battery.100percent.bolt", tint: Color(red: 0.4, green: 0.87, blue: 0.5),
                                title: "充電中", detail: "已接上電源", trailing: "\(new.percent)%",
                                battery: new.percent, charging: true)
        }
        if !new.onAC, let mark = lowLevels.first(where: { new.percent <= $0 && old.percent > $0 }) {
            return IslandNotice(icon: mark <= 10 ? "battery.0percent" : "battery.25percent",
                                tint: mark <= 10 ? .red : .orange,
                                title: "電量低", detail: "剩 \(new.percent)%，記得充電", trailing: "\(new.percent)%",
                                battery: new.percent)
        }
        return nil
    }
}
