import Combine
import Darwin
import Foundation
import IOKit
import SwiftUI

/// CPU, memory, disk and network figures of this Mac (public Mach / BSD calls only, read-only). It only samples
/// while someone is looking (the 系統 page is open).
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    struct Snapshot: Equatable {
        var cpu: Double = 0              // 0…1, all cores
        var memUsed: Double = 0          // bytes
        var memTotal: Double = 1
        var diskFree: Double = 0
        var diskTotal: Double = 1
        var netIn: Double = 0            // bytes per second
        var netOut: Double = 0
        var gpu: Double?                 // 0…1; nil when the GPU does not report it
        var gpuMemory: Double = 0        // bytes in use by the GPU
    }

    @Published private(set) var snap = Snapshot()
    /// Recent samples for the sparklines (oldest first): CPU and memory 0…1, network in bytes per second.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var netInHistory: [Double] = []
    @Published private(set) var netOutHistory: [Double] = []
    private var timer: Timer?
    private var lastCPU: [UInt32]?
    private var lastNet: (UInt64, UInt64, Date)?
    private var watchers = 0

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.commonModeTimer(interval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    private func sample() {
        var s = snap
        if let ticks = Self.cpuTicks() {
            if let last = lastCPU { s.cpu = Self.load(from: last, to: ticks) }
            lastCPU = ticks
        }
        (s.memUsed, s.memTotal) = Self.memory()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            s.diskTotal = Double(v.volumeTotalCapacity ?? 1)
        }
        let (i, o) = Self.networkBytes()
        let now = Date()
        if let (li, lo, lt) = lastNet {
            let dt = max(0.2, now.timeIntervalSince(lt))
            // Totals drop when a 32-bit counter wraps or an interface goes away (VPN, sleep): skip that sample.
            s.netIn = i >= li ? Double(i - li) / dt : 0
            s.netOut = o >= lo ? Double(o - lo) / dt : 0
        }
        lastNet = (i, o, now)
        if let g = Self.gpuStats() { s.gpu = g.utilization; s.gpuMemory = g.memory }
        snap = s
        if let g = s.gpu { gpuHistory = Array((gpuHistory + [g]).suffix(40)) }
        cpuHistory = Array((cpuHistory + [s.cpu]).suffix(40))
        memHistory = Array((memHistory + [s.memUsed / s.memTotal]).suffix(40))
        netInHistory = Array((netInHistory + [s.netIn]).suffix(40))
        netOutHistory = Array((netOutHistory + [s.netOut]).suffix(40))
    }

    /// GPU busy share and memory in use, from the graphics driver's own statistics (IOAccelerator, no permission).
    static func gpuStats() -> (utilization: Double, memory: Double)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: (Double, Double)?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any], let g = gpu(from: stats) else { continue }
            if best == nil || g.utilization > best!.0 { best = (g.utilization, g.memory) }   // the busiest GPU
        }
        return best.map { (utilization: $0.0, memory: $0.1) }
    }

    static func gpu(from stats: [String: Any]) -> (utilization: Double, memory: Double)? {
        guard let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue, (0...100).contains(u) else { return nil }
        let mem = (stats["In use system memory"] as? NSNumber)?.doubleValue ?? (stats["vramUsedBytes"] as? NSNumber)?.doubleValue ?? 0
        return (u / 100, max(0, mem))
    }

    /// user, system, idle, nice ticks summed over all CPUs.
    static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    /// Busy share between two tick samples (user, system, idle, nice).
    static func load(from a: [UInt32], to b: [UInt32]) -> Double {
        guard a.count == 4, b.count == 4 else { return 0 }
        let d = zip(a, b).map { Double($1 &- $0) }
        let total = d.reduce(0, +)
        return total > 0 ? (d[0] + d[1] + d[3]) / total : 0
    }

    /// Used (app + wired + compressed, like Activity Monitor's "Memory Used") and total bytes.
    static func memory() -> (Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard r == KERN_SUCCESS else { return (0, total) }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (min(max(used, 0), total), total)
    }

    /// Bytes received / sent on all non-loopback interfaces since boot.
    static func networkBytes() -> (UInt64, UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var i: UInt64 = 0, o: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            i += UInt64(data.pointee.ifi_ibytes); o += UInt64(data.pointee.ifi_obytes)
        }
        return (i, o)
    }

    /// Value and unit apart, so the number can be large and the unit small: (12.3, "GB").
    static func split(_ b: Double, perSecond: Bool = false) -> (String, String) {
        let units = perSecond ? ["B/s", "KB/s", "MB/s", "GB/s"] : ["B", "KB", "MB", "GB", "TB"]
        let base = perSecond ? 1000.0 : 1024.0
        var v = max(0, b), i = 0
        while v >= base * 0.95 && i < units.count - 1 { v /= base; i += 1 }
        let num = v >= 100 || i == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return (num, units[i])
    }

    static func bytes(_ b: Double, perSecond: Bool = false) -> String {
        let (n, u) = split(b, perSecond: perSecond); return "\(n) \(u)"
    }
}

/// The expanded "系統" page: one card per metric (value, unit, recent history), like a system monitor.
struct SystemPageView: View {
    @ObservedObject private var mon = SystemMonitor.shared
    @ObservedObject private var battery = BatteryStatus.shared

    private static let cpuTint = Color(red: 0.38, green: 0.78, blue: 1)
    private static let gpuTint = Color(red: 1, green: 0.5, blue: 0.62)
    private static let memTint = Color(red: 0.72, green: 0.56, blue: 1)
    private static let diskTint = Color(red: 1, green: 0.72, blue: 0.32)
    private static let netTint = Color(red: 0.42, green: 0.9, blue: 0.62)

    var body: some View {
        let s = mon.snap
        let mem = SystemMonitor.split(s.memUsed), memTotal = SystemMonitor.split(s.memTotal)
        let free = SystemMonitor.split(s.diskFree)
        let down = SystemMonitor.split(s.netIn, perSecond: true), up = SystemMonitor.split(s.netOut, perSecond: true)
        HStack(spacing: 8) {
            card("CPU", "cpu", Self.cpuTint, value: "\(Int((s.cpu * 100).rounded()))", unit: "%",
                 caption: "\(ProcessInfo.processInfo.activeProcessorCount) 核心") {
                chart(mon.cpuHistory, max: 1, tint: Self.cpuTint)
            }
            if let g = s.gpu {
                let gm = SystemMonitor.split(s.gpuMemory)
                card("GPU", "cpu.fill", Self.gpuTint, value: "\(Int((g * 100).rounded()))", unit: "%",
                     caption: "使用 \(gm.0) \(gm.1)") {
                    chart(mon.gpuHistory, max: 1, tint: Self.gpuTint)
                }
            }
            card("記憶體", "memorychip", Self.memTint, value: mem.0, unit: mem.1,
                 caption: "\(Int((s.memUsed / s.memTotal * 100).rounded()))% / \(Int((Double(memTotal.0) ?? 0).rounded())) \(memTotal.1)") {
                chart(mon.memHistory, max: 1, tint: Self.memTint)
            }
            card("可用空間", "internaldrive", Self.diskTint, value: free.0, unit: free.1,
                 caption: "已用 \(Int(((1 - s.diskFree / s.diskTotal) * 100).rounded()))%") {
                bar(1 - s.diskFree / s.diskTotal, tint: Self.diskTint)
            }
            card("網路", "network", Self.netTint, value: down.0, unit: down.1,
                 caption: "↑ \(up.0) \(up.1)") {
                let top = max(1, (mon.netInHistory + mon.netOutHistory).max() ?? 1)
                ZStack {
                    chart(mon.netInHistory, max: top, tint: Self.netTint)
                    Sparkline(values: mon.netOutHistory.map { $0 / top }).stroke(Color.white.opacity(0.45), lineWidth: 1)
                }
            }
            if let b = battery.reading {
                let low = b.percent <= 20 && !b.onAC
                card("電池", b.onAC ? "battery.100percent.bolt" : "battery.75percent", low ? .red : Self.netTint,
                     value: "\(b.percent)", unit: "%", caption: b.onAC ? "接上電源" : "使用電池") {
                    bar(Double(b.percent) / 100, tint: low ? .red : Self.netTint)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { mon.watch(); battery.refresh() }
        .onDisappear { mon.unwatch() }
    }

    private func card<G: View>(_ title: String, _ icon: String, _ tint: Color, value: String, unit: String, caption: String,
                               @ViewBuilder graph: () -> G) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase)
            }
            .foregroundColor(tint)
            // One line whatever the number: a long one shrinks instead of wrapping and stretching the card.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white).contentTransition(.numericText()).animation(.snappy, value: value)
                    .lineLimit(1).layoutPriority(1)
                Text(unit).font(.system(size: 9.5, weight: .medium)).foregroundColor(.white.opacity(0.5)).lineLimit(1)
            }
            .lineLimit(1).minimumScaleFactor(0.55)
            .frame(height: 24, alignment: .leading)
            graph().frame(height: 26).padding(.top, 2)
            Text(caption).font(.system(size: 9.5)).monospacedDigit().foregroundColor(.white.opacity(0.45)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    private func chart(_ values: [Double], max top: Double, tint: Color) -> some View {
        let v = values.map { $0 / top }
        return ZStack {
            Sparkline(values: v, closed: true).fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            Sparkline(values: v).stroke(tint, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        .animation(.easeInOut(duration: 0.4), value: values)
    }

    private func bar(_ value: Double, tint: Color) -> some View {
        VStack {
            Spacer(minLength: 0)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(tint.gradient).frame(width: g.size.width * min(max(value, 0.02), 1))
                }
            }
            .frame(height: 6)
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: value)
    }
}

/// A line through the values (0…1), optionally closed to the bottom for a filled area.
struct Sparkline: Shape {
    var values: [Double]
    var closed = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = r.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: r.minX + CGFloat(i) * step, y: r.maxY - CGFloat(min(max(v, 0), 1)) * r.height)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        if closed { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath() }
        return p
    }
}

/// The current battery reading for the 系統 page.
final class BatteryStatus: ObservableObject {
    static let shared = BatteryStatus()
    @Published private(set) var reading: BatteryMonitor.Reading?
    func refresh() { reading = BatteryMonitor.read() }
}
