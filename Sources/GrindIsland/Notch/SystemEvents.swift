import AppKit
import Carbon
import Network

/// Mac state changes shown in the island: network up/down, displays plugged in or out, Low Power Mode, overheating and
/// keyboard input source. Public, permission-free sources only (other apps' notifications cannot be read without
/// Full Disk Access, so they are not mirrored).
final class SystemEvents {
    static let shared = SystemEvents()

    struct Net: Equatable { let online: Bool; let kind: String }

    private let pathMonitor = NWPathMonitor()
    private var lastNet: Net?
    private var offlineShown = false
    private var screens: [String] = []
    private var lastInput: String?
    private var lastThermal = ProcessInfo.processInfo.thermalState

    func start() {
        screens = NSScreen.screens.map(\.localizedName)
        lastInput = Self.inputSourceName()
        pathMonitor.pathUpdateHandler = { [weak self] p in
            let n = Net(online: p.status == .satisfied, kind: Self.kind(of: p))
            DispatchQueue.main.async { self?.netChanged(n) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            guard AppSettings.shared.batteryNotices else { return }
            NoticeCenter.shared.post(Self.lowPowerNotice(ProcessInfo.processInfo.isLowPowerModeEnabled), seconds: 2.5)
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermalChanged()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.inputChanged() }
    }

    // MARK: Handlers (the first reading after launch is never announced)

    /// A drop must last 3 s before it is shown (Wi-Fi blips, waking from sleep), and "back online" only follows a shown drop.
    private func netChanged(_ n: Net) {
        let old = lastNet
        lastNet = n
        guard AppSettings.shared.systemNotices, let note = Self.netNotice(from: old, to: n) else { return }
        if n.online {
            if offlineShown { offlineShown = false; NoticeCenter.shared.post(note, seconds: 2.5) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, self.lastNet?.online == false, !self.offlineShown else { return }
                self.offlineShown = true
                NoticeCenter.shared.post(note, seconds: 3)
            }
        }
    }

    private func screensChanged() {
        let now = NSScreen.screens.map(\.localizedName)
        defer { screens = now }
        guard AppSettings.shared.systemNotices, let note = Self.displayNotice(old: screens, new: now) else { return }
        NoticeCenter.shared.post(note, seconds: 2.5)
    }

    private func thermalChanged() {
        let t = ProcessInfo.processInfo.thermalState
        defer { lastThermal = t }
        guard AppSettings.shared.batteryNotices, let note = Self.thermalNotice(from: lastThermal, to: t) else { return }
        NoticeCenter.shared.post(note, seconds: 4)
    }

    private func inputChanged() {
        guard let name = Self.inputSourceName(), name != lastInput else { return }
        lastInput = name
        guard AppSettings.shared.inputSourceNotices else { return }
        NoticeCenter.shared.post(Self.inputNotice(name), seconds: 1.2)
    }

    // MARK: Pure notice builders

    /// Only going offline and coming back (switching interfaces, VPNs coming and going are not news).
    static func netNotice(from old: Net?, to new: Net) -> IslandNotice? {
        guard let old = old, old.online != new.online else { return nil }
        if !new.online { return IslandNotice(icon: "wifi.slash", tint: .orange, title: "網路", detail: "已中斷連線", trailing: "離線") }
        let icon = new.kind == "Wi-Fi" ? "wifi" : new.kind == "有線網路" ? "cable.connector" : "network"
        return IslandNotice(icon: icon, tint: .green, title: "網路", detail: "已連線（\(new.kind)）", trailing: "✓")
    }

    static func displayNotice(old: [String], new: [String]) -> IslandNotice? {
        if let added = new.first(where: { !old.contains($0) }) {
            return IslandNotice(icon: "display", tint: .white, title: "已連接螢幕", detail: clip(added), trailing: "\(new.count)")
        }
        if let removed = old.first(where: { !new.contains($0) }) {
            return IslandNotice(icon: "display", tint: .white, title: "已中斷螢幕", detail: clip(removed), trailing: "\(new.count)")
        }
        return nil
    }

    static func lowPowerNotice(_ on: Bool) -> IslandNotice {
        IslandNotice(icon: "leaf.fill", tint: on ? .yellow : .white, title: "低耗電模式", detail: on ? "已開啟" : "已關閉", trailing: on ? "開" : "關")
    }

    /// Only when it gets worse into "serious" or "critical" (the Mac is slowing itself down).
    static func thermalNotice(from old: ProcessInfo.ThermalState, to new: ProcessInfo.ThermalState) -> IslandNotice? {
        guard new.rawValue > old.rawValue, new == .serious || new == .critical else { return nil }
        let critical = new == .critical
        return IslandNotice(icon: "thermometer.high", tint: critical ? .red : .orange, title: "Mac 溫度偏高",
                            detail: critical ? "已大幅降速，建議關掉吃效能的工作" : "系統正在降速散熱", trailing: critical ? "!!" : "!")
    }

    static func inputNotice(_ name: String) -> IslandNotice {
        let n = clip(name)
        return IslandNotice(icon: "keyboard", tint: .white, title: "輸入法", detail: n, trailing: String(n.prefix(1)))
    }

    // MARK: Readers

    private static func kind(of p: NWPath) -> String {
        p.usesInterfaceType(.wifi) ? "Wi-Fi" : p.usesInterfaceType(.wiredEthernet) ? "有線網路" : p.usesInterfaceType(.cellular) ? "行動網路" : "其他網路"
    }

    private static func inputSourceName() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Names come from devices and the system: shown only, on one line.
    private static func clip(_ s: String) -> String { String(s.replacingOccurrences(of: "\n", with: " ").prefix(40)) }
}
