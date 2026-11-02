import SwiftUI

/// One lyric line with a left-to-right sweep highlight. Short lines sit centered; lines wider than the
/// available space scroll as a looping marquee (starting from the beginning for every new line).
public struct FlowingKaraokeView: View {
    public let text: String
    public let translation: String?
    public let progress: CGFloat
    /// When set, the sweep reads the live position on every frame instead of using `progress`, so only this view redraws.
    public let progressProvider: (() -> CGFloat)?
    public let fontSize: CGFloat
    public let highlight: Color
    public let glow: Bool
    public let weight: Font.Weight
    public let centered: Bool

    public init(
        text: String,
        translation: String? = nil,
        progress: CGFloat,
        progressProvider: (() -> CGFloat)? = nil,
        fontSize: CGFloat = 13.5,
        highlight: Color = .white,
        glow: Bool = true,
        weight: Font.Weight = .bold,
        centered: Bool = false
    ) {
        self.text = text
        self.translation = translation
        self.progress = progress
        self.progressProvider = progressProvider
        self.fontSize = fontSize
        self.highlight = highlight
        self.glow = glow
        self.weight = weight
        self.centered = centered
    }

    @State private var textW: CGFloat = 0
    @State private var boxW: CGFloat = 0
    @State private var startDate = Date()

    private let marqueeSpeed: Double = 34   // pt per second
    private let marqueeGap: CGFloat = 44
    private let marqueeDelay: Double = 0.8  // pause at the start of every line
    private let fadeInset: CGFloat = 14     // start inside the edge fade so the first characters are fully visible

    private struct WKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var overflows: Bool { boxW > 0 && textW > boxW + 1 }

    /// The lyric text with its sweep highlight; measured once for the marquee.
    private func line(_ p: CGFloat) -> some View {
        sweptText(p)
            .background(GeometryReader { g in Color.clear.preference(key: WKey.self, value: g.size.width) })
    }

    /// A single gradient whose stops follow the progress: no per-frame layout. The edge has a soft feather and travels
    /// feather-width past the end of the text, so at 100% the last characters are fully lit.
    private func sweepMask(_ progress: CGFloat) -> some View {
        let w = max(textW, 1)
        let feather: CGFloat = 22
        let p = min(max(progress, 0), 1)
        let activeX = (w + feather) * p
        let solid = min(max((activeX - feather) / w, 0), 1)
        let edge = min(max(activeX / w, solid), 1)
        return LinearGradient(
            stops: [.init(color: .white, location: 0), .init(color: .white, location: solid),
                    .init(color: .clear, location: edge), .init(color: .clear, location: 1)],
            startPoint: .leading, endPoint: .trailing)
    }

    private func sweptText(_ progress: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundColor(highlight.opacity(0.4))
                .fixedSize()

            Text(text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundColor(highlight)
                .shadow(color: highlight.opacity(glow ? 0.7 : 0), radius: 3, x: 0, y: 0)
                .fixedSize()
                .mask(sweepMask(progress))
        }
    }

    public var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 3) {
            // The container only reserves one line of height and takes the width it is given. The (possibly
            // much wider) text is an overlay, so it can never enlarge the container or spill outside it.
            Text("A")
                .font(.system(size: fontSize, weight: weight))
                .opacity(0)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in   // 30 fps: the sweep looks the same, half the work
                        let p = progressProvider?() ?? progress
                        let elapsed = timeline.date.timeIntervalSince(startDate)
                        let travel = textW + marqueeGap
                        let shift = CGFloat(max(elapsed - marqueeDelay, 0) * marqueeSpeed)
                            .truncatingRemainder(dividingBy: max(travel, 1))

                        HStack(spacing: marqueeGap) {
                            line(p)
                            if overflows { line(p) }   // second copy makes the loop seamless
                        }
                        .fixedSize()
                        .offset(x: overflows ? fadeInset - shift : (centered ? (boxW - textW) / 2 : 0))
                        .opacity(textW > 0 && boxW > 0 ? 1 : 0)   // a fresh view starts unmeasured: hide it until placed, or it flashes at the left edge then jumps to centre
                    }
                }
                .background(GeometryReader { g in Color.clear.onAppear { boxW = g.size.width }.onChange(of: g.size.width) { _, new in boxW = new } })
                .onPreferenceChange(WKey.self) { textW = $0 }
                .clipped()
                .mask(edgeFade)
                .onChange(of: text) { startDate = Date() }

            if let trans = translation, !trans.isEmpty {
                Text(trans)
                    .font(.system(size: max(fontSize - 3.2, 10), weight: .semibold))
                    .foregroundColor(Color(red: 0.42, green: 0.82, blue: 1.0))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    /// Soft fade at both ends while the marquee is running.
    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: overflows ? .clear : .black, location: 0),
                .init(color: .black, location: overflows ? 0.06 : 0),
                .init(color: .black, location: overflows ? 0.94 : 1),
                .init(color: overflows ? .clear : .black, location: 1)
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}
