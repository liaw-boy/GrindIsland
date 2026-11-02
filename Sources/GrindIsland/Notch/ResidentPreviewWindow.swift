import AppKit
import SwiftUI

/// `--preview-resident`: puts the mock-up of the planned resident capsule on the real screen, over the notch, and
/// leaves it there (it ignores the mouse). Test aid only; `--flat-top` shows the flat-topped variant.
/// Whether the pointer is near the preview capsule; observed by the preview view.
final class ResidentPreviewState: ObservableObject {
    @Published var near = false
}

private struct ResidentPreviewHost: View {
    @ObservedObject var state: ResidentPreviewState
    let notch: CGSize, wing: CGFloat, capsuleHeight: CGFloat, roundTop: Bool, showRange: Bool
    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            ResidentPreviewView(notch: notch, wing: wing, showRange: showRange, roundTop: roundTop,
                                height: capsuleHeight, showBrowserBand: true, near: state.near)
        }
    }
}

/// `--preview-music`: plays the content rule in a loop (music → waiting notification → music → done → music → resident),
/// every 3.5 seconds; `--variant=0..3` holds one state (0 music, 1 waiting, 2 done, 3 resident).
private struct MusicPreviewHost: View {
    @ObservedObject var state: ResidentPreviewState
    let notch: CGSize, wing: CGFloat, height: CGFloat
    @State private var step = 0
    private let timer = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()
    private let fixed: Int? = CommandLine.arguments.first(where: { $0.hasPrefix("--variant=") }).flatMap { Int($0.dropFirst(10)) }

    var body: some View {
        let order = MusicPreviewView.demoOrder
        let v = fixed.flatMap { MusicPreviewView.Variant(rawValue: $0) } ?? order[step % order.count]
        VStack(spacing: 6) {
            MusicPreviewView(notch: notch, wing: wing, height: height, variant: v, near: state.near)
            Text(v.title)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.75)))
        }
        // Stick to the top edge of the window, or the stack is centred vertically (and the notch outline drawn too low).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(timer) { _ in if fixed == nil { step += 1 } }
    }
}

enum ResidentPreviewWindow {
    private static var panel: NSPanel?
    private static var monitor: Any?
    private static let state = ResidentPreviewState()

    static func showIfRequested() {
        let stages = CommandLine.arguments.contains("--preview-stages")
        let music = CommandLine.arguments.contains("--preview-music")
        guard CommandLine.arguments.contains("--preview-resident") || stages || music else { return }
        let geom = NotchGeometry.shared
        let screen = AppSettings.shared.targetScreen
        let notch = geom.hasNotch ? geom.realNotchSize : CGSize(width: 220, height: max(geom.notchHeight, 32))
        // `--wing=N`: width of each wing in pt (default 35: notch 220 + 70 = 290, the width of the playing capsule).
        let wingWidth = CGFloat(CommandLine.arguments.first(where: { $0.hasPrefix("--wing=") }).flatMap { Double($0.dropFirst(7)) } ?? 35)
        // `--height=N`: height of the capsule in pt (default 48: 10pt taller than the notch, still above the browser's × at y 52).
        let capsuleHeight = CGFloat(CommandLine.arguments.first(where: { $0.hasPrefix("--height=") }).flatMap { Double($0.dropFirst(9)) } ?? 48)
        // The music/notification capsule is 330 wide (wing 55): the most that leaves the menu-bar icons on the right free.
        let musicWing = CGFloat(CommandLine.arguments.first(where: { $0.hasPrefix("--music-wing=") }).flatMap { Double($0.dropFirst(13)) } ?? 55)
        let width: CGFloat = 640, height: CGFloat = stages ? 250 : 120
        let rect = NSRect(x: screen.frame.midX - width / 2 + geom.realNotchDX, y: screen.frame.maxY - height, width: width, height: height)

        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: 30)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = ResidentPreviewView(
            notch: notch, wing: wingWidth,
            showRange: !CommandLine.arguments.contains("--no-range"),
            roundTop: !CommandLine.arguments.contains("--flat-top"),
            height: capsuleHeight, showBrowserBand: true)
        let roundTop = !CommandLine.arguments.contains("--flat-top")
        let showRange = !CommandLine.arguments.contains("--no-range")
        if music {
            p.contentView = NSHostingView(rootView: MusicPreviewHost(state: state, notch: notch, wing: musicWing, height: capsuleHeight))
        } else if stages {
            p.contentView = NSHostingView(rootView: ZStack(alignment: .top) { Color.clear; StagesPreviewView(notch: notch, residentHeight: capsuleHeight) })
        }
        if !stages {
            _ = view
            if !music { p.contentView = NSHostingView(rootView: ResidentPreviewHost(
                state: state, notch: notch, wing: wingWidth, capsuleHeight: capsuleHeight, roundTop: roundTop, showRange: showRange)) }
            // The pointer is "near" within 10pt of the capsule (the island's default sensitivity), measured in screen coordinates.
            let capsule = CGRect(x: screen.frame.midX - (notch.width + 2 * wingWidth) / 2 + geom.realNotchDX,
                                 y: screen.frame.maxY - capsuleHeight,
                                 width: notch.width + 2 * wingWidth, height: capsuleHeight)
            let zone = capsule.insetBy(dx: -10, dy: -10).union(CGRect(x: capsule.minX, y: capsule.maxY, width: capsule.width, height: 40))
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
                let near = zone.contains(NSEvent.mouseLocation)
                if near != state.near { state.near = near }
            }
            // `--preview-hover-demo`: toggles "near" every 2s with no pointer (so the animation can be recorded).
            if CommandLine.arguments.contains("--preview-hover-demo") {
                Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in state.near.toggle() }
            }
        }
        p.orderFrontRegardless()
        panel = p
    }
}
