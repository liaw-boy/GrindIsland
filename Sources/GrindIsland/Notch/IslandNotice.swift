import Combine
import Foundation
import SwiftUI

/// A short-lived message from the Mac itself (charging, a timer finishing, an upcoming meeting...), shown in the
/// collapsed island in place of the music for a few seconds. Agent notices still take priority.
struct IslandNotice: Equatable {
    var icon: String          // SF Symbol for the left wing
    var tint: Color
    var title: String         // coloured, before the colon
    var detail: String
    var trailing: String      // short text for the right wing ("82%", "25:00")
    /// Battery notices: the level, drawn as a battery that fills up to it instead of `icon` / `trailing`.
    var battery: Int? = nil
    var charging = false
    /// Level 0…1 drawn as a bar in place of the text (volume).
    var meter: Double? = nil
    /// Earbuds: their glyph inside a battery ring, and the charging case in the right wing.
    var earbuds: Earbuds? = nil

    struct Earbuds: Equatable {
        var buds: Int?          // nil until the earbuds report it (the ring stays empty)
        var caseLevel: Int?
        var caseIcon: String
    }
}

/// A device glyph inside a battery ring (green, red when low) that fills to the level, iPhone battery-widget style.
struct DeviceRing: View {
    let icon: String
    let level: Int?
    var size: CGFloat = 30
    @State private var shown: CGFloat = 0

    private var tint: Color { (level ?? 100) <= 20 ? .red : .green }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.6)
            Circle().trim(from: 0, to: shown)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: icon).font(.system(size: size * 0.45, weight: .semibold)).foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .onAppear { fill() }
        .onChange(of: level) { _, _ in fill() }
    }

    private func fill() {
        guard let l = level else { return }
        withAnimation(.easeOut(duration: 0.55).delay(0.1)) { shown = CGFloat(min(max(l, 0), 100)) / 100 }
    }
}

/// A level bar (volume) that glides to each new value.
struct MeterBar: View {
    let value: Double
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.18))
            GeometryReader { g in
                Capsule().fill(Color.white).frame(width: max(6, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(width: 170, height: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: value)
    }
}

/// A ring (like the phone's charging ring) that fills from empty to `percent` when it appears; charging: a bolt in the
/// middle and a bright head that keeps running around the ring.
struct BatteryGauge: View {
    let percent: Int
    let charging: Bool
    let tint: Color
    @State private var level: CGFloat = 0
    @State private var spin = false
    @State private var glow = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: 3.2)
            Circle().trim(from: 0, to: level)
                .stroke(tint, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.6), radius: 2)
            if charging {
                Circle().trim(from: 0, to: 0.12)   // a glint chasing around the ring
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 270 : -90))
                    .mask(Circle().trim(from: 0, to: level).stroke(lineWidth: 3.2).rotationEffect(.degrees(-90)))
                // Lit, not dimmed: a bright bolt with a glow that breathes while it charges.
                Image(systemName: "bolt.fill").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    .shadow(color: tint, radius: glow ? 5 : 2)
                    .shadow(color: tint.opacity(0.8), radius: glow ? 9 : 3)
            } else {
                Image(systemName: "exclamationmark").font(.system(size: 14, weight: .heavy)).foregroundColor(tint)
            }
        }
        .frame(width: 30, height: 30)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.15)) { level = CGFloat(min(max(percent, 0), 100)) / 100 }
            if charging {
                withAnimation(.linear(duration: 1.4).delay(0.75).repeatForever(autoreverses: false)) { spin = true }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { glow = true }
            }
        }
    }
}

/// "0%" counting up to the value as it animates.
struct CountingPercent: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("\(Int(value.rounded()))%") }
}

/// Counts from 0 to `percent` alongside `BatteryGauge`.
struct BatteryPercentText: View {
    let percent: Int
    @State private var shown: Double = 0
    var body: some View {
        CountingPercent(value: shown)
            .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.15)) { shown = Double(percent) } }
    }
}

final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()
    @Published private(set) var current: IslandNotice?
    private var hideTimer: Timer?

    /// Ends the notice showing now (if any).
    func dismiss() {
        DispatchQueue.main.async { [self] in hideTimer?.invalidate(); current = nil }
    }

    /// Shows `notice` for `seconds` (replacing any notice already showing).
    func post(_ notice: IslandNotice, seconds: TimeInterval = 4) {
        DispatchQueue.main.async { [self] in
            current = notice
            hideTimer?.invalidate()
            hideTimer = Timer.commonModeTimer(interval: seconds, repeats: false) { [weak self] _ in self?.current = nil }
        }
    }
}
