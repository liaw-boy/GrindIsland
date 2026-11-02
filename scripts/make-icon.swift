// Draws the app icon (original artwork) and writes Support/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the project folder; needs iconutil, part of macOS)
import AppKit
import SwiftUI

struct Icon: View {
    /// The 16–64 px artwork: drawn for its size (bigger cat, thicker ears, solid eyes, no glow or shadow), not the
    /// large icon shrunk, so it stays crisp in Finder lists and the settings sidebar.
    var small = false
    private let shape = RoundedRectangle(cornerRadius: 186, style: .continuous)

    var body: some View {
        ZStack {
            // macOS icon grid: an 824pt rounded square centred on the 1024 canvas.
            shape
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.36, blue: 1.0), Color(red: 0.98, green: 0.42, blue: 0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(small ? 0 : 0.22), .clear], startPoint: .top, endPoint: .center)))
                // Small sizes: an 896 tile, so its edges land on whole pixels at 16 and 32 px (1 and 2 px margins).
                .frame(width: small ? 896 : 824, height: small ? 896 : 824)
                .shadow(color: .black.opacity(small ? 0 : 0.35), radius: 22, y: 12)
            if small { smallCat.offset(y: 48) } else { catIsland.offset(y: 40) }
        }
        .frame(width: 1024, height: 1024)
    }

    /// Small sizes: the same cat, larger in the tile, with heavier features and flat colours (glows turn to mush).
    private var smallCat: some View {
        ZStack {
            Ear().fill(Color.black).frame(width: 300, height: 280).rotationEffect(.degrees(-10)).offset(x: -250, y: -195)
            Ear().fill(Color.black).frame(width: 300, height: 280).rotationEffect(.degrees(10)).offset(x: 250, y: -195)
            Capsule().fill(Color.black).frame(width: 768, height: 416)
            HStack(spacing: 150) {
                Capsule().fill(Color(red: 0.55, green: 0.92, blue: 1)).frame(width: 128, height: 192)   // 2 × 3 px at 16 px
                Capsule().fill(Color(red: 0.55, green: 0.92, blue: 1)).frame(width: 128, height: 192)
            }
            .offset(y: 6)
        }
    }

    /// The island as a black cat: a capsule with two ears and two glowing eyes. Bold enough to read at 16 px.
    private var catIsland: some View {
        let eye = LinearGradient(colors: [.white, Color(red: 0.45, green: 0.88, blue: 1)], startPoint: .top, endPoint: .bottom)
        return ZStack {
            Ear().fill(Color.black).frame(width: 210, height: 200).rotationEffect(.degrees(-12)).offset(x: -215, y: -150)
            Ear().fill(Color.black).frame(width: 210, height: 200).rotationEffect(.degrees(12)).offset(x: 215, y: -150)
            Capsule().fill(Color.black).frame(width: 660, height: 330)
            HStack(spacing: 150) {
                Capsule().fill(eye).frame(width: 78, height: 128)
                Capsule().fill(eye).frame(width: 78, height: 128)
            }
            .shadow(color: Color(red: 0.45, green: 0.88, blue: 1).opacity(0.9), radius: 26)
            .offset(y: 4)
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
    }
}

struct Ear: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX + r.width * 0.15, y: r.minY + r.height * 0.2))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - r.width * 0.15, y: r.minY + r.height * 0.2))
        p.closeSubpath()
        return p
    }
}

@MainActor func run() throws {
    let fm = FileManager.default
    let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
    try? fm.removeItem(at: set)
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let px = size * scale
        let r = ImageRenderer(content: Icon(small: px <= 64).scaleEffect(CGFloat(px) / 1024).frame(width: CGFloat(px), height: CGFloat(px)))
        r.scale = 1
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try png.write(to: set.appendingPathComponent(name))
    }
    let out = URL(fileURLWithPath: "Support/AppIcon.icns")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", out.path]
    try p.run(); p.waitUntilExit()
    // A preview next to it, for looking at the design.
    let r = ImageRenderer(content: Icon()); r.scale = 1
    if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-preview.png"))
    }
    print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
}
try MainActor.assumeIsolated { try run() }
