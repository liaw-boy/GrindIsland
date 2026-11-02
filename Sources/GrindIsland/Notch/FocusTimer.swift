import Combine
import Foundation
import SwiftUI

/// Pomodoro-style focus timer: a focus block, then a break, counting cycles. The clock is a wall-clock end date,
/// so sleep or a busy main thread never makes it drift.
struct FocusClock: Equatable {
    enum Phase: Equatable { case focus, rest }
    struct Preset: Equatable, Identifiable {
        let focus: Int, rest: Int          // minutes
        var id: Int { focus }
        var label: String { "\(focus)/\(rest)" }
    }
    static let presets = [Preset(focus: 25, rest: 5), Preset(focus: 50, rest: 10), Preset(focus: 15, rest: 3)]

    var preset = presets[0]
    var phase = Phase.focus
    /// Set while running.
    var endsAt: Date?
    /// Set while paused (seconds left).
    var pausedLeft: TimeInterval?
    var cycles = 0

    var isRunning: Bool { endsAt != nil }
    var isActive: Bool { endsAt != nil || pausedLeft != nil }
    var phaseLength: TimeInterval { TimeInterval((phase == .focus ? preset.focus : preset.rest) * 60) }

    func remaining(at now: Date) -> TimeInterval {
        if let e = endsAt { return max(0, e.timeIntervalSince(now)) }
        return pausedLeft ?? phaseLength
    }
    /// 0 at the start of the phase, 1 at its end.
    func progress(at now: Date) -> Double { 1 - remaining(at: now) / phaseLength }

    mutating func start(_ p: Preset, at now: Date) {
        preset = p; phase = .focus; pausedLeft = nil
        endsAt = now.addingTimeInterval(phaseLength)
    }
    mutating func pause(at now: Date) {
        guard let e = endsAt else { return }
        pausedLeft = max(0, e.timeIntervalSince(now)); endsAt = nil
    }
    mutating func resume(at now: Date) {
        guard let left = pausedLeft else { return }
        endsAt = now.addingTimeInterval(left); pausedLeft = nil
    }
    mutating func stop() { endsAt = nil; pausedLeft = nil; phase = .focus }

    /// Advances when the running phase is over: focus → rest (starts at once, counts a cycle), rest → stopped.
    /// Returns the phase that just ended.
    mutating func tick(at now: Date) -> Phase? {
        guard let e = endsAt, now >= e else { return nil }
        let ended = phase
        if phase == .focus {
            cycles += 1; phase = .rest; endsAt = now.addingTimeInterval(phaseLength)
        } else {
            stop()
        }
        return ended
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    @Published private(set) var clock = FocusClock()
    /// Ticks once a second while the timer is active, so views showing the time redraw.
    @Published private(set) var now = Date()
    private var ticker: Timer?

    static let focusTint = Color(red: 1.0, green: 0.45, blue: 0.35)
    static let restTint = Color(red: 0.35, green: 0.8, blue: 1.0)
    var tint: Color { clock.phase == .focus ? Self.focusTint : Self.restTint }

    func start(_ p: FocusClock.Preset) { clock.start(p, at: Date()); run() }
    func pause() { clock.pause(at: Date()); update() }
    func resume() { clock.resume(at: Date()); run() }
    func stop() { clock.stop(); update() }
    /// Ends the current phase now (focus → break, break → done).
    func skip() { if clock.endsAt != nil { clock.endsAt = Date() } else if clock.pausedLeft != nil { clock.resume(at: Date()); clock.endsAt = Date() }; fire() }

    private func run() {
        update()
        guard ticker == nil else { return }
        ticker = Timer.commonModeTimer(interval: 1, repeats: true) { [weak self] _ in self?.fire() }
    }

    private func fire() {
        if let ended = clock.tick(at: Date()) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            NoticeCenter.shared.post(ended == .focus
                ? IslandNotice(icon: "cup.and.saucer.fill", tint: Self.restTint, title: "專注完成",
                               detail: "休息 \(clock.preset.rest) 分鐘・已完成 \(clock.cycles) 輪", trailing: "☕︎")
                : IslandNotice(icon: "flame.fill", tint: Self.focusTint, title: "休息結束",
                               detail: "準備開始下一輪專注", trailing: "↻"), seconds: 6)
        }
        update()
    }

    private func update() {
        now = Date()
        if !clock.isRunning { ticker?.invalidate(); ticker = nil }
    }
}

/// Progress ring with the phase colour (empty → full as the phase runs).
struct FocusRing: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 2.6

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
    }
}

/// The expanded "計時" page: a big ring with the time, presets and controls.
struct FocusTimerView: View {
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        let c = timer.clock
        HStack(spacing: 28) {
            ZStack {
                FocusRing(progress: c.isActive ? c.progress(at: timer.now) : 0, tint: timer.tint, lineWidth: 7)
                VStack(spacing: 2) {
                    Text(FocusClock.format(c.remaining(at: timer.now)))
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: Int(c.remaining(at: timer.now)))
                    Text(!c.isActive ? "準備專注" : c.phase == .focus ? (c.isRunning ? "專注中" : "已暫停") : "休息中")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(timer.tint)
                }
            }
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(FocusClock.presets) { p in
                        let on = c.preset == p
                        Button { timer.start(p) } label: {
                            Text(p.label).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundColor(on ? .black : .white.opacity(0.85))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(on ? timer.tint : Color.white.opacity(0.1)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("專注 \(p.focus) 分鐘・休息 \(p.rest) 分鐘")
                    }
                }
                HStack(spacing: 10) {
                    control(c.isRunning ? "pause.fill" : "play.fill", big: true) {
                        if c.isRunning { timer.pause() } else if c.pausedLeft != nil { timer.resume() } else { timer.start(c.preset) }
                    }
                    control("forward.end.fill") { timer.skip() }.disabled(!c.isActive).opacity(c.isActive ? 1 : 0.35)
                    control("stop.fill") { timer.stop() }.disabled(!c.isActive).opacity(c.isActive ? 1 : 0.35)
                }
                HStack(spacing: 4) {
                    ForEach(0..<max(4, c.cycles), id: \.self) { i in
                        Circle().fill(i < c.cycles ? FocusTimer.focusTint : Color.white.opacity(0.15)).frame(width: 7, height: 7)
                    }
                    Text("已完成 \(c.cycles) 輪").font(.system(size: 11)).foregroundColor(.white.opacity(0.55)).padding(.leading, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: c)
    }

    private func control(_ icon: String, big: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: big ? 15 : 12, weight: .bold))
                .foregroundColor(big ? .black : .white)
                .frame(width: big ? 38 : 30, height: big ? 38 : 30)
                .background(Circle().fill(big ? Color.white : Color.white.opacity(0.12)))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}
