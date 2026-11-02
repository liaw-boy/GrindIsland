import AppKit
import SwiftUI

/// The expanded "控制" page: volume, display brightness and keyboard light sliders, and buttons for a screenshot,
/// a screen recording, mute and turning the display off. Levels are read while the page is open.
struct ControlsView: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    @State private var volume: Double = 0
    @State private var muted = false
    @State private var display: Double = 0
    @State private var keyboard: Double?
    @State private var timer: Timer?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 12) {
                level(muted ? "speaker.slash.fill" : "speaker.wave.3.fill", value: $volume) { v in
                    guard let dev = MediaKeys.Audio.defaultOutput() else { return }
                    if muted { _ = MediaKeys.Audio.setMuted(dev, false); muted = false }
                    _ = MediaKeys.Audio.setVolume(dev, Float(v))
                }
                level("sun.max.fill", value: $display) { v in _ = BrightnessMonitor.shared.setDisplay(Float(v)) }
                if keyboard != nil {
                    level("light.max", value: Binding(get: { keyboard ?? 0 }, set: { keyboard = $0 })) { v in
                        _ = BrightnessMonitor.shared.setKeyboard(Float(v))
                    }
                }
            }
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: [GridItem(.fixed(96), spacing: 8), GridItem(.fixed(96), spacing: 8)], spacing: 8) {
                tile("camera.viewfinder", "截圖", tint: .white) { recorder.screenshot() }
                tile(recorder.recording ? "stop.fill" : "record.circle", recorder.recording
                     ? ScreenRecorder.elapsed(recorder.now.timeIntervalSince(recorder.started ?? recorder.now)) : "螢幕錄影",
                     tint: .red, on: recorder.recording) { recorder.toggle() }
                tile(muted ? "speaker.slash.fill" : "speaker.fill", muted ? "已靜音" : "靜音", tint: .orange, on: muted) {
                    guard let dev = MediaKeys.Audio.defaultOutput() else { return }
                    if MediaKeys.Audio.setMuted(dev, !muted) { muted.toggle() }
                }
                tile("moon.zzz.fill", "關閉螢幕", tint: .indigo) { Self.sleepDisplay() }
            }
            .frame(width: 200)
        }
        .padding(.horizontal, 26).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { read(); timer = Timer.commonModeTimer(interval: 1, repeats: true) { _ in read() } }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func read() {
        if let dev = MediaKeys.Audio.defaultOutput() {
            volume = Double(MediaKeys.Audio.volume(dev) ?? 0)
            muted = MediaKeys.Audio.muted(dev) ?? false
        }
        display = Double(BrightnessMonitor.shared.displayLevel() ?? 0)
        keyboard = BrightnessMonitor.shared.keyboardLevel().map(Double.init)
    }

    /// A slider row: icon, track, percentage. `apply` runs as it moves.
    private func level(_ icon: String, value: Binding<Double>, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon, variableValue: value.wrappedValue).font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85)).frame(width: 22)
            IslandSlider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; apply($0) }), range: 0...1)
            Text("\(Int((value.wrappedValue * 100).rounded()))").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundColor(.white.opacity(0.6)).frame(width: 28, alignment: .trailing)
        }
    }

    private func tile(_ icon: String, _ title: String, tint: Color, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                    .foregroundColor(on ? .white : tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: on && icon == "stop.fill")
                Text(title).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(.white.opacity(on ? 1 : 0.8)).lineLimit(1)
            }
            .frame(width: 96, height: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? tint.opacity(0.85) : Color.white.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The display sleeps now (locking it if a password is required after sleep).
    static func sleepDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}
