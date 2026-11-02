import SwiftUI

/// Settings controls drawn in the island's own look (black, translucent white, springy), instead of AppKit's.
enum IslandStyleKit {
    static let accent = Color(red: 0.35, green: 0.8, blue: 1.0)     // the island's cyan (譯, selected states)
    static let on = Color(red: 0.3, green: 0.8, blue: 0.45)         // the island's green (allow, charging)
    static let card = Color.white.opacity(0.06)
    static let cardLine = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.5)
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.75)
}

/// A pill switch: grey track, green when on, a white knob that springs across.
struct IslandSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? IslandStyleKit.on : Color.white.opacity(0.14))
                Circle().fill(Color.white).padding(2.5).shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            }
            .frame(width: 36, height: 21)
            .animation(IslandStyleKit.spring, value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

/// Choices in one capsule; the chosen one sits on a white pill that slides to it.
struct IslandSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    /// The small version used inside the island (page switches at the bottom of a page).
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i], chosen = o.value == selection
                Text(o.label).font(.system(size: compact ? 10.5 : 12, weight: chosen ? .semibold : .medium))
                    .foregroundColor(chosen ? .black : .white.opacity(0.75))
                    .frame(maxWidth: .infinity).padding(.vertical, compact ? 3 : 5)
                    .background {
                        if chosen { Capsule().fill(Color.white.opacity(0.92)).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(IslandStyleKit.spring) { selection = o.value } }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// A thin track with a cyan fill and a white knob; drag or click anywhere on it.
struct IslandSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 4)
                Capsule().fill(IslandStyleKit.accent).frame(width: max(4, w * f), height: 4)
                Circle().fill(Color.white).frame(width: 14, height: 14).shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: (w - 14) * f)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let t = min(max(Double(d.location.x / max(w, 1)), 0), 1)
                var v = range.lowerBound + t * (range.upperBound - range.lowerBound)
                if step > 0 { v = (v / step).rounded() * step }
                value = min(max(v, range.lowerBound), range.upperBound)
            })
        }
        .frame(height: 18)
    }
}

/// A small capsule button; `.danger` is red for removing things.
struct IslandButton: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundColor(danger ? Color(red: 1, green: 0.45, blue: 0.45) : .white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A drop-down whose closed state is a capsule with the current choice (the open menu is the system's).
struct IslandMenu<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].label) { selection = options[i].value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? "").font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
