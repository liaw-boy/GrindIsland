import SwiftUI

/// Vector cat drawn in code. The pose follows the agent state:
/// working → typing on a laptop, waiting → standing with a waving paw, idle → curled up asleep.
/// The look (fur, pattern, ears, accessory) comes from `CatLook` and has nothing to do with the agent kind.
struct CatAvatar: View {
    let state: AgentState
    let look: CatLook
    /// A fixed moment, for still renderings (previews / tests). `nil` = animate in real time.
    var time: Double? = nil

    private let ink = Color(red: 0.12, green: 0.10, blue: 0.13)
    private let pink = Color(red: 1.0, green: 0.72, blue: 0.77)

    var body: some View {
        if let time = time {
            canvas(time)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                canvas(timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func canvas(_ t: Double) -> some View {
        Canvas { context, size in
            var g = context
            g.scaleBy(x: size.width / 44, y: size.height / 44)
            switch state {
            case .working: drawWorking(&g, t)
            case .waitingApproval: drawAlert(&g, t)
            case .idle, .completed: drawSleeping(&g, t)
            }
        }
    }

    // MARK: - Colors by look

    private var pawColor: Color {
        switch look.pattern {
        case .tuxedo: return look.accent
        case .colorpoint: return look.mark
        default: return look.fur
        }
    }

    // MARK: - Poses

    private func drawWorking(_ g: inout GraphicsContext, _ t: Double) {
        let y = 7 + CGFloat(sin(t * 2.2)) * 0.5
        drawTail(&g, from: CGPoint(x: 32, y: 38), to: CGPoint(x: 41, y: 27), bend: CGFloat(sin(t * 2.0)) * 2)
        drawBody(&g, CGRect(x: 11, y: 24, width: 22, height: 17))
        drawHead(&g, y: y)
        drawFace(&g, y: y, wide: false, closed: false, t: t)

        // Laptop seen from behind, accent dot pulses like a logo
        g.fill(Path(roundedRect: CGRect(x: 8, y: 33, width: 28, height: 9), cornerRadius: 2), with: .color(Color(white: 0.22)))
        let glow = 0.45 + 0.35 * sin(t * 3)
        g.fill(Path(ellipseIn: CGRect(x: 20.6, y: 36, width: 2.8, height: 2.8)), with: .color(.white.opacity(glow)))

        // Paws tapping alternately
        let l = CGFloat(sin(t * 13)) * 1.3
        let r = CGFloat(cos(t * 13)) * 1.3
        g.fill(Path(ellipseIn: CGRect(x: 10, y: 29.5 + l, width: 7, height: 5)), with: .color(pawColor))
        g.fill(Path(ellipseIn: CGRect(x: 27, y: 29.5 + r, width: 7, height: 5)), with: .color(pawColor))
    }

    private func drawAlert(_ g: inout GraphicsContext, _ t: Double) {
        let hop = CGFloat(abs(sin(t * 5))) * 1.5
        let y = 7 - hop
        drawTail(&g, from: CGPoint(x: 12, y: 38), to: CGPoint(x: 4, y: 22), bend: CGFloat(sin(t * 6)) * 3)
        drawBody(&g, CGRect(x: 11, y: 24 - hop, width: 22, height: 18))
        g.fill(Path(ellipseIn: CGRect(x: 12, y: 37, width: 8, height: 5)), with: .color(pawColor))
        g.fill(Path(ellipseIn: CGRect(x: 24, y: 37, width: 8, height: 5)), with: .color(pawColor))

        // Raised, waving paw
        let pivot = CGPoint(x: 31, y: 28 - hop)
        // Tilted outward so the arm is not hidden behind the head
        let angle = -Double.pi / 2 + 0.85 + sin(t * 7) * 0.3
        let tip = CGPoint(x: pivot.x + CGFloat(cos(angle)) * 13, y: pivot.y + CGFloat(sin(angle)) * 13)
        var arm = Path()
        arm.move(to: pivot)
        arm.addLine(to: tip)
        g.stroke(arm, with: .color(look.fur), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
        g.fill(Path(ellipseIn: CGRect(x: tip.x - 3.4, y: tip.y - 3.4, width: 6.8, height: 6.8)), with: .color(pink))

        drawHead(&g, y: y)
        drawFace(&g, y: y, wide: true, closed: false, t: t)
    }

    private func drawSleeping(_ g: inout GraphicsContext, _ t: Double) {
        let breathe = CGFloat(sin(t * 1.8)) * 0.6

        var tail = Path()
        tail.move(to: CGPoint(x: 10, y: 39))
        tail.addQuadCurve(to: CGPoint(x: 38, y: 36), control: CGPoint(x: 24, y: 46))
        g.stroke(tail, with: .color(look.fur), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
        if look.pattern == .colorpoint {
            g.fill(Path(ellipseIn: CGRect(x: 34.5, y: 32.5, width: 7, height: 7)), with: .color(look.mark))
        }

        drawBody(&g, CGRect(x: 5, y: 22 - breathe / 2, width: 34, height: 19 + breathe))

        // The head is the normal head, smaller and tipped onto the body, with closed eyes.
        var h = g
        h.translateBy(x: 17, y: 28.5)
        h.rotate(by: .degrees(-9))
        h.scaleBy(x: 0.7, y: 0.7)
        h.translateBy(x: -22, y: -20.5)
        drawHead(&h, y: 7)
        drawFace(&h, y: 7, wide: false, closed: true, t: t)

        // Floating z's
        for i in 0..<2 {
            let phase = (t * 0.5 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            let text = Text("z").font(.system(size: 7 + CGFloat(i) * 2, weight: .bold)).foregroundColor(.white.opacity(0.7 * (1 - phase)))
            g.draw(text, at: CGPoint(x: 30 + CGFloat(phase) * 6, y: 15 - CGFloat(phase) * 9))
        }
    }

    // MARK: - Body and tail

    /// Thick, fluffy tail (a thin line reads as a rat tail), with a darker tip.
    private func drawTail(_ g: inout GraphicsContext, from: CGPoint, to: CGPoint, bend: CGFloat) {
        var tail = Path()
        tail.move(to: from)
        tail.addQuadCurve(to: to, control: CGPoint(x: to.x + bend + (to.x > from.x ? 5 : -5), y: (from.y + to.y) / 2 + 6))
        let width: CGFloat = look.fluffy ? 8.5 : 6.5
        g.stroke(tail, with: .color(look.fur), style: StrokeStyle(lineWidth: width, lineCap: .round))
        if look.pattern == .tabby {
            // a couple of rings
            for f in [0.35, 0.65] as [CGFloat] {
                let p = CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
                g.fill(Path(ellipseIn: CGRect(x: p.x - 1.4, y: p.y - 3.2, width: 2.8, height: 6.4)), with: .color(look.mark.opacity(0.7)))
            }
        }
        let tipColor: Color = look.pattern == .colorpoint ? look.mark : Color.black.opacity(0.3)
        g.fill(Path(ellipseIn: CGRect(x: to.x - width / 2, y: to.y - width / 2, width: width, height: width)), with: .color(tipColor))
    }

    private func drawBody(_ g: inout GraphicsContext, _ rect: CGRect) {
        let body = Path(ellipseIn: rect)
        g.fill(body, with: .color(look.fur))
        var c = g
        c.clip(to: body)
        switch look.pattern {
        case .tabby:
            for dx in [-6.0, 0.0, 6.0] as [CGFloat] {
                var s = Path()
                s.move(to: CGPoint(x: rect.midX + dx, y: rect.minY - 1))
                s.addQuadCurve(to: CGPoint(x: rect.midX + dx * 1.5, y: rect.minY + 6), control: CGPoint(x: rect.midX + dx + 1.5, y: rect.minY + 3))
                c.stroke(s, with: .color(look.mark.opacity(0.75)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
        case .tuxedo:
            c.fill(Path(ellipseIn: CGRect(x: rect.midX - 7, y: rect.minY + 4, width: 14, height: rect.height)), with: .color(look.accent))
        case .patches:
            c.fill(Path(ellipseIn: CGRect(x: rect.minX - 3, y: rect.minY - 2, width: 12, height: 10)), with: .color(look.mark))
            c.fill(Path(ellipseIn: CGRect(x: rect.maxX - 9, y: rect.midY, width: 13, height: 11)), with: .color(look.accent))
        case .solid, .colorpoint:
            break
        }
    }

    // MARK: - Head

    private func earColor(left: Bool) -> Color {
        switch look.pattern {
        case .colorpoint: return look.mark
        case .patches: return left ? look.mark : look.fur
        default: return look.fur
        }
    }

    private func drawHead(_ g: inout GraphicsContext, y: CGFloat) {
        // Fluffy: a ruff behind the head and big cheek tufts
        if look.fluffy {
            g.fill(Path(ellipseIn: CGRect(x: 5, y: y + 11, width: 34, height: 15)), with: .color(look.fur))
        }

        for side in [-1.0, 1.0] as [CGFloat] {
            let color = earColor(left: side < 0)
            switch look.ears {
            case .pointed:
                var ear = Path()
                ear.move(to: CGPoint(x: 22 + side * 14, y: y + 11))
                ear.addLine(to: CGPoint(x: 22 + side * 11.5, y: y - 4))
                ear.addLine(to: CGPoint(x: 22 + side * 3, y: y + 5))
                ear.closeSubpath()
                g.fill(ear, with: .color(color))

                var inner = Path()
                inner.move(to: CGPoint(x: 22 + side * 11.5, y: y + 8.5))
                inner.addLine(to: CGPoint(x: 22 + side * 10.5, y: y - 0.5))
                inner.addLine(to: CGPoint(x: 22 + side * 5.5, y: y + 5.5))
                inner.closeSubpath()
                g.fill(inner, with: .color(pink.opacity(0.9)))
            case .folded:
                // small flaps lying forward and outward
                var ear = Path()
                ear.move(to: CGPoint(x: 22 + side * 6, y: y + 3.5))
                ear.addQuadCurve(to: CGPoint(x: 22 + side * 15.5, y: y + 6.5), control: CGPoint(x: 22 + side * 12, y: y))
                ear.addQuadCurve(to: CGPoint(x: 22 + side * 11, y: y + 12), control: CGPoint(x: 22 + side * 17, y: y + 10.5))
                ear.closeSubpath()
                g.fill(ear, with: .color(color))
            }
        }

        // Head
        let head = Path(ellipseIn: CGRect(x: 7, y: y + 3.5, width: 30, height: 20))
        g.fill(head, with: .color(look.fur))

        // Cheek tufts
        for side in [-1.0, 1.0] as [CGFloat] {
            var tuft = Path()
            if look.fluffy {
                tuft.move(to: CGPoint(x: 22 + side * 14, y: y + 12))
                tuft.addLine(to: CGPoint(x: 22 + side * 20, y: y + 15))
                tuft.addLine(to: CGPoint(x: 22 + side * 15.5, y: y + 17))
                tuft.addLine(to: CGPoint(x: 22 + side * 19.5, y: y + 20.5))
                tuft.addLine(to: CGPoint(x: 22 + side * 14, y: y + 21.5))
            } else {
                tuft.move(to: CGPoint(x: 22 + side * 15, y: y + 15))
                tuft.addLine(to: CGPoint(x: 22 + side * 18.5, y: y + 20.5))
                tuft.addLine(to: CGPoint(x: 22 + side * 12, y: y + 21))
            }
            tuft.closeSubpath()
            g.fill(tuft, with: .color(look.fur))
        }

        // Head pattern, clipped to the head
        var c = g
        c.clip(to: head)
        switch look.pattern {
        case .tabby:
            for dx in [-3.0, 0.0, 3.0] as [CGFloat] {
                var stripe = Path()
                stripe.move(to: CGPoint(x: 22 + dx, y: y + 3.8))
                stripe.addLine(to: CGPoint(x: 22 + dx, y: y + (dx == 0 ? 8.5 : 7)))
                c.stroke(stripe, with: .color(look.mark.opacity(0.8)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
            for side in [-1.0, 1.0] as [CGFloat] {   // cheek marks
                var m = Path()
                m.move(to: CGPoint(x: 22 + side * 15, y: y + 14))
                m.addLine(to: CGPoint(x: 22 + side * 10.5, y: y + 15))
                c.stroke(m, with: .color(look.mark.opacity(0.7)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
        case .tuxedo:
            c.fill(Path(ellipseIn: CGRect(x: 13, y: y + 12.5, width: 18, height: 13)), with: .color(look.accent))
            c.fill(Path(roundedRect: CGRect(x: 20.5, y: y + 6, width: 3, height: 9), cornerRadius: 1.5), with: .color(look.accent))
        case .patches:
            c.fill(Path(ellipseIn: CGRect(x: 4, y: y + 1, width: 17, height: 13)), with: .color(look.mark))
            if look.accent != look.fur {
                c.fill(Path(ellipseIn: CGRect(x: 27, y: y + 5, width: 12, height: 10)), with: .color(look.accent))
            }
        case .colorpoint:
            c.fill(Path(ellipseIn: CGRect(x: 12, y: y + 9, width: 20, height: 16)), with: .color(look.mark.opacity(0.9)))
        case .solid:
            break
        }
    }

    private func drawFace(_ g: inout GraphicsContext, y: CGFloat, wide: Bool, closed: Bool, t: Double) {
        let blink = t.truncatingRemainder(dividingBy: 3.4) < 0.12

        // Light muzzle (not for the colorpoint mask, which is dark)
        if look.pattern != .colorpoint {
            g.fill(Path(ellipseIn: CGRect(x: 16.5, y: y + 16, width: 11, height: 7.5)), with: .color(look.accent))
        }

        // Cat eyes with a vertical slit pupil, or closed arcs when asleep
        for x in [15.5, 28.5] as [CGFloat] {
            let cy = y + 13.5
            if closed {
                var arc = Path()
                arc.move(to: CGPoint(x: x - 2.6, y: cy))
                arc.addQuadCurve(to: CGPoint(x: x + 2.6, y: cy), control: CGPoint(x: x, y: cy + 2.8))
                g.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                continue
            }
            let w: CGFloat = wide ? 5.6 : 5.2
            let h: CGFloat = blink ? 0.8 : (wide ? 6.4 : 3.4)
            g.fill(Path(ellipseIn: CGRect(x: x - w / 2, y: cy - h / 2, width: w, height: h)), with: .color(look.eye))
            if !blink {
                g.fill(Path(ellipseIn: CGRect(x: x - 0.7, y: cy - h / 2 + 0.3, width: 1.4, height: h - 0.6)), with: .color(ink))
                if wide {
                    g.fill(Path(ellipseIn: CGRect(x: x - 1.9, y: cy - 2.6, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.9)))
                }
            }
        }

        var nose = Path()
        nose.move(to: CGPoint(x: 20.8, y: y + 17.2))
        nose.addLine(to: CGPoint(x: 23.2, y: y + 17.2))
        nose.addLine(to: CGPoint(x: 22, y: y + 18.6))
        nose.closeSubpath()
        g.fill(nose, with: .color(pink))

        if wide {
            g.fill(Path(ellipseIn: CGRect(x: 20.6, y: y + 19.6, width: 2.8, height: 3)), with: .color(ink))
        } else {
            // "ω" mouth
            var mouth = Path()
            mouth.move(to: CGPoint(x: 22, y: y + 18.6))
            mouth.addLine(to: CGPoint(x: 22, y: y + 19.8))
            mouth.move(to: CGPoint(x: 19.4, y: y + 19.6))
            mouth.addQuadCurve(to: CGPoint(x: 22, y: y + 19.8), control: CGPoint(x: 20.6, y: y + 21.6))
            mouth.addQuadCurve(to: CGPoint(x: 24.6, y: y + 19.6), control: CGPoint(x: 23.4, y: y + 21.6))
            g.stroke(mouth, with: .color(ink.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }

        // Short whiskers (dark enough to show on a white cat)
        let whisker = (look.fur.luminanceIsHigh ? Color.black.opacity(0.28) : Color.white.opacity(0.55))
        for side in [-1.0, 1.0] as [CGFloat] {
            var w = Path()
            w.move(to: CGPoint(x: 22 + side * 6.5, y: y + 18))
            w.addLine(to: CGPoint(x: 22 + side * 13, y: y + 16.8))
            w.move(to: CGPoint(x: 22 + side * 6.5, y: y + 20))
            w.addLine(to: CGPoint(x: 22 + side * 13, y: y + 21))
            g.stroke(w, with: .color(whisker), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }

        drawAccessory(&g, y: y)
    }

    private func drawAccessory(_ g: inout GraphicsContext, y: CGFloat) {
        let col = look.accessoryColor
        switch look.accessory {
        case .none:
            break
        case .collar:
            var arc = Path()
            arc.move(to: CGPoint(x: 12.5, y: y + 21))
            arc.addQuadCurve(to: CGPoint(x: 31.5, y: y + 21), control: CGPoint(x: 22, y: y + 27))
            g.stroke(arc, with: .color(col), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            g.fill(Path(ellipseIn: CGRect(x: 20.6, y: y + 23.4, width: 2.8, height: 2.8)), with: .color(Color(red: 1, green: 0.84, blue: 0.3)))
        case .scarf:
            var band = Path()
            band.move(to: CGPoint(x: 12, y: y + 20.5))
            band.addQuadCurve(to: CGPoint(x: 32, y: y + 20.5), control: CGPoint(x: 22, y: y + 27.5))
            g.stroke(band, with: .color(col), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
            g.fill(Path(roundedRect: CGRect(x: 26, y: y + 22.5, width: 3.6, height: 7), cornerRadius: 1.4), with: .color(col.opacity(0.9)))
        case .bow:
            var left = Path(); left.move(to: CGPoint(x: 13, y: y + 4)); left.addLine(to: CGPoint(x: 8, y: y + 0.5)); left.addLine(to: CGPoint(x: 8.2, y: y + 7.5)); left.closeSubpath()
            var right = Path(); right.move(to: CGPoint(x: 13, y: y + 4)); right.addLine(to: CGPoint(x: 18, y: y + 0.5)); right.addLine(to: CGPoint(x: 17.8, y: y + 7.5)); right.closeSubpath()
            g.fill(left, with: .color(col)); g.fill(right, with: .color(col))
            g.fill(Path(ellipseIn: CGRect(x: 11.4, y: y + 2.5, width: 3.2, height: 3.2)), with: .color(col.opacity(0.85)))
        case .glasses:
            for x in [15.5, 28.5] as [CGFloat] {
                g.stroke(Path(ellipseIn: CGRect(x: x - 4.2, y: y + 9.4, width: 8.4, height: 8.4)), with: .color(col), style: StrokeStyle(lineWidth: 0.9))
            }
            var bridge = Path(); bridge.move(to: CGPoint(x: 19.8, y: y + 13.2)); bridge.addLine(to: CGPoint(x: 24.2, y: y + 13.2))
            g.stroke(bridge, with: .color(col), style: StrokeStyle(lineWidth: 0.9))
        case .flower:
            let center = CGPoint(x: 14, y: y + 5.5)
            for k in 0..<5 {
                let a = Double(k) / 5 * 2 * .pi
                let p = CGPoint(x: center.x + CGFloat(cos(a)) * 2.4, y: center.y + CGFloat(sin(a)) * 2.4)
                g.fill(Path(ellipseIn: CGRect(x: p.x - 1.7, y: p.y - 1.7, width: 3.4, height: 3.4)), with: .color(col))
            }
            g.fill(Path(ellipseIn: CGRect(x: center.x - 1.3, y: center.y - 1.3, width: 2.6, height: 2.6)), with: .color(Color(red: 1, green: 0.55, blue: 0.2)))
        }
    }
}

private extension Color {
    /// Rough "is this a light color" test, to pick a whisker color that shows up.
    var luminanceIsHigh: Bool {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? .gray
        return 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent > 0.62
    }
}
