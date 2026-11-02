import SwiftUI
import Combine

/// A mock-up of the planned always-on ("resident") capsule, used only to look at its shape and size before building it.
/// It lives in the menu-bar band (the notch's height), is as wide as the notch plus a wing on each side, and its middle is
/// hidden behind the notch, so only the two wings show: a cat on the left, a status on the right.
struct ResidentPreviewView: View {
    let notch: CGSize
    let wing: CGFloat
    /// Draw a thin white outline around the real notch.
    var showRange = true
    /// true = fully round capsule, false = flat on top (like the notch itself) and round at the bottom.
    var roundTop = true
    /// 0 = agents working, 1 = an agent waits for you. nil = alternate every few seconds.
    var fixedPhase: Int? = nil
    var caption = true
    /// Height of the capsule. nil = the notch's height. Taller than the notch = a chin below it.
    var height: CGFloat? = nil
    /// Draw the band where the browser's close (×) and new-tab (+) buttons are, to check the capsule stays above it.
    var showBrowserBand = false
    /// The pointer is near: swell like the real island does (wider and a little taller, the content moves outward).
    var near = false

    @State private var phase = 0
    private let timer = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()

    private var pillWidth: CGFloat { notch.width + 2 * wing + (near ? 16 : 0) }
    private var pillHeight: CGFloat { (height ?? notch.height) + (near ? 6 : 0) }

    var body: some View {
        let current = fixedPhase ?? phase
        let waiting = current == 1
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                pillShape.fill(Color.black).frame(width: pillWidth, height: pillHeight)

                HStack(spacing: 0) {
                    CatAvatar(state: waiting ? .waitingApproval : .working, look: CatLook.all[0], time: fixedPhase == nil ? nil : 0.7)
                        .frame(width: min(26, wing - 8), height: min(26, wing - 8))
                        .scaleEffect(near ? 1.1 : 1)
                        .offset(x: near ? -6 : 0)
                        .frame(width: wing)
                    Color.clear.frame(width: notch.width)
                    HStack(spacing: 4) {
                        Circle().fill(waiting ? Color.orange : Color(red: 0.4, green: 0.87, blue: 0.6)).frame(width: 7, height: 7)
                        Text(waiting ? "1" : "2")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .offset(x: near ? 6 : 0)
                    .frame(width: wing)
                }
                .frame(width: pillWidth, height: pillHeight)

                if showBrowserBand {
                    Rectangle().fill(Color.red.opacity(0.35)).frame(width: pillWidth + 60, height: 14).offset(y: 52)
                }

                if showRange {
                    // The real notch, outlined: 1pt white line.
                    UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                        .stroke(Color.white, lineWidth: 1)
                        .frame(width: notch.width, height: notch.height)
                }
            }
            .frame(width: pillWidth + 60, height: showBrowserBand ? 70 : pillHeight, alignment: .top)

            if caption {
                Text("白線＝瀏海 \(Int(notch.width))×\(Int(notch.height))　黑＝常駐膠囊 \(Int(pillWidth))×\(Int(pillHeight))（兩側各 \(Int(wing))）\(showBrowserBand ? "　紅帶＝瀏覽器 ×/+ 52~66" : "")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: near)
        .onReceive(timer) { _ in if fixedPhase == nil { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { phase = 1 - phase } } }
    }

    private var pillShape: some Shape {
        // One curvature rule for every state: min(44, half the height). Small shapes are fully round, big ones stop at 44.
        let r = min(44, pillHeight / 2)
        return UnevenRoundedRectangle(
            topLeadingRadius: roundTop ? r : 0,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: roundTop ? r : 0
        )
    }
}

/// All stages of the fused capsule drawn as colored outlines on top of each other, to compare their sizes and where
/// they start. Test aid for `--preview-stages`.
struct StagesPreviewView: View {
    let notch: CGSize
    var residentHeight: CGFloat = 48
    /// Where the capsule starts below the screen's top edge (the notch's height minus the 4pt overlap).
    var top: CGFloat { notch.height - 4 }

    private struct Stage { let name: String; let w: CGFloat; let h: CGFloat; let y: CGFloat; let radius: CGFloat; let color: Color }

    private var stages: [Stage] {
        [
            Stage(name: "常駐 290×\(Int(residentHeight))", w: 290, h: residentHeight, y: 0, radius: residentHeight / 2, color: Color(red: 0.4, green: 0.87, blue: 0.6)),
            Stage(name: "播放 290×56", w: 290, h: 56, y: top, radius: 28, color: Color(red: 0.35, green: 0.65, blue: 1.0)),
            Stage(name: "靠近凸出 306×62", w: 306, h: 62, y: top, radius: 31, color: Color.orange),
            Stage(name: "展開 572×172", w: 572, h: 172, y: top, radius: 26, color: Color(red: 0.75, green: 0.55, blue: 1.0))
        ]
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                Color.clear.frame(width: 600, height: top + 172 + 4)
                ForEach(Array(stages.enumerated()), id: \.offset) { _, st in
                    RoundedRectangle(cornerRadius: st.radius, style: .continuous)
                        .stroke(st.color, lineWidth: 1.5)
                        .frame(width: st.w, height: st.h)
                        .offset(y: st.y)
                }
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: notch.width, height: notch.height)
                // Where the browser's tab-bar buttons (close ×, new tab +) are on the user's screen (measured from a screenshot):
                // the island must stay above this band to leave them clickable.
                Rectangle()
                    .fill(Color.red.opacity(0.35))
                    .frame(width: 600, height: 14)
                    .offset(y: 52)
            }
            HStack(spacing: 10) {
                legend("紅帶＝瀏覽器 × / + 按鈕 y 52~66", .red)
                legend("瀏海 \(Int(notch.width))×\(Int(notch.height))", .white)
                ForEach(Array(stages.enumerated()), id: \.offset) { _, st in legend(st.name, st.color) }
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.75)))
    }
}

/// The capsule's content rule: music first; the cat appears only for a notification (or when nothing plays but agents run);
/// the two never share the capsule — the content is swapped. The capsule keeps one size in every state.
struct MusicPreviewView: View {
    enum Variant: Int, CaseIterable {
        case music, waiting, done, resident
        var title: String {
            switch self {
            case .music: return "① 放歌中：只顯示歌（封面｜均衡器，歌詞在瀏海下）"
            case .waiting: return "② Agent 要你批准：換成貓＋訊息，留著直到你處理"
            case .done: return "③ Agent 做完了：換成貓＋訊息，約 4 秒後回到歌"
            case .resident: return "④ 沒放歌、有 Agent 在跑：常駐的貓＋數量"
            }
        }
    }
    /// The order the demo plays them in: after each notification it goes back to the music.
    static let demoOrder: [Variant] = [.music, .waiting, .music, .done, .music, .resident]

    let notch: CGSize
    let wing: CGFloat
    let height: CGFloat
    let variant: Variant
    var near = false

    private let tint = Color(red: 0.62, green: 0.76, blue: 0.95)
    private let green = Color(red: 0.4, green: 0.87, blue: 0.6)
    private var cover: some View {
        LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.5), Color(red: 0.35, green: 0.45, blue: 0.9)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private func bars(_ t: Double, _ n: Int = 4) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<n, id: \.self) { i in
                Capsule().fill(tint).frame(width: 2.4, height: 4 + 9 * CGFloat((sin(t * (3 + Double(i) * 0.9) + Double(i)) + 1) / 2))
            }
        }
    }

    var body: some View {
        let w = notch.width + 2 * wing + (near ? 16 : 0)
        let h = height + (near ? 6 : 0)
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: min(44, h / 2), style: .continuous).fill(Color.black).frame(width: w, height: h)

                // Everything that changes between states sits in one group, swapped as a whole (never layered).
                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        wingLeft(t).frame(width: wing)
                        Color.clear.frame(width: notch.width)
                        wingRight(t).frame(width: wing)
                    }
                    .frame(width: w, height: h)   // wings span the whole capsule: centre their content on its middle, not the notch band

                    strip.frame(width: w, height: h - notch.height).offset(y: notch.height)
                }
                .id(variant)
                .transition(.opacity)

                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: notch.width, height: notch.height)
                Rectangle().fill(Color.red.opacity(0.35)).frame(width: w + 60, height: 14).offset(y: 52)
            }
            .frame(width: w, height: 70, alignment: .top)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: near)
            .animation(.easeInOut(duration: 0.25), value: variant)
        }
        .frame(width: notch.width + 2 * (wing + 20), height: 70, alignment: .top)
    }

    @ViewBuilder private func wingLeft(_ t: Double) -> some View {
        switch variant {
        case .music:
            cover.frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .waiting:
            CatAvatar(state: .waitingApproval, look: CatLook.all[0], time: t).frame(width: 30, height: 30)
        case .done:
            CatAvatar(state: .completed, look: CatLook.all[4], time: t).frame(width: 30, height: 30)
                .offset(y: -2.8)   // the curled-up pose is drawn low in its box; this puts its centre on the wing centre
        case .resident:
            CatAvatar(state: .working, look: CatLook.all[0], time: t).frame(width: 30, height: 30)
        }
    }

    @ViewBuilder private func wingRight(_ t: Double) -> some View {
        switch variant {
        case .music:
            bars(t)
        case .waiting:
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 7, height: 7).opacity(0.55 + 0.45 * sin(t * 6))
                Text("1").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(.white)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundColor(green)
        case .resident:
            HStack(spacing: 4) {
                Circle().fill(green).frame(width: 7, height: 7)
                Text("2").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(.white)
            }
        }
    }

    @ViewBuilder private var strip: some View {
        switch variant {
        case .music:
            HStack(spacing: 10) {
                Text("夜明け前の街を歩く").font(.system(size: 11.5, weight: .semibold)).foregroundColor(tint).frame(maxWidth: .infinity)
                Text("走過黎明前的街").font(.system(size: 11.5, weight: .semibold)).foregroundColor(tint.opacity(0.7)).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        case .waiting:
            Text("proj-gamma 在等你授權").font(.system(size: 12, weight: .semibold)).foregroundColor(Color.orange)
        case .done:
            Text("proj-alpha 完成了 · 2 分 13 秒").font(.system(size: 12, weight: .semibold)).foregroundColor(green)
        case .resident:
            Text("2 個 Agent 工作中").font(.system(size: 11.5, weight: .medium)).foregroundColor(.white.opacity(0.6))
        }
    }
}
