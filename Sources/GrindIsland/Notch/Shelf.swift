import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Files parked on the island. Only the file's location is remembered (nothing is copied or moved), for a day.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    struct Item: Identifiable, Equatable, Codable {
        var id: String { path }
        let path: String
        let added: Date
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
    }

    static let maxItems = 30
    static let keepSeconds: TimeInterval = 24 * 3600
    private static let key = "shelfItems"

    @Published private(set) var items: [Item] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        items = Self.pruned(saved, now: Date())
    }

    /// Adds local files (anything else is ignored); newest first, no duplicates.
    func add(_ urls: [URL], now: Date = Date()) {
        let new = urls.filter { $0.isFileURL }.map { $0.standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !new.isEmpty else { return }
        items = Self.pruned(new.map { Item(path: $0, added: now) } + items.filter { !new.contains($0.path) }, now: now)
        save()
    }

    func remove(_ item: Item) { items.removeAll { $0 == item }; save() }
    func clear() { items = []; save() }

    /// Drops files that are gone or older than a day, and keeps at most `maxItems`.
    static func pruned(_ items: [Item], now: Date) -> [Item] {
        Array(items.filter { now.timeIntervalSince($0.added) < keepSeconds && FileManager.default.fileExists(atPath: $0.path) }
            .prefix(maxItems))
    }

    private func save() { defaults.set(try? JSONEncoder().encode(items), forKey: Self.key) }

    func airDrop(_ items: [Item]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items.map(\.url))
    }
}

/// Taildrop (Tailscale's file sending) through the `tailscale` command line tool, when it is installed.
/// Arguments go straight to the process (no shell), and a target must be one Tailscale itself listed.
enum Taildrop {
    struct Target: Identifiable, Equatable { let id: String; let name: String }   // id = Tailscale IP

    static var cli: String? {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Devices that can receive files right now (empty when Tailscale is stopped or not installed).
    static func targets() -> [Target] {
        guard let cli = cli, let out = run(cli, ["file", "cp", "--targets"]) else { return [] }
        return parseTargets(out)
    }

    /// Lines of `tailscale file cp --targets`: "<ip>\t<name>[\t...]".
    static func parseTargets(_ out: String) -> [Target] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 2, isSafeTarget(f[0]) else { return nil }
            return Target(id: f[0], name: f[1].isEmpty ? f[0] : f[1])
        }
    }

    /// An IPv4/IPv6 address or host name only: it becomes the "<target>:" argument.
    static func isSafeTarget(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".:-_".contains($0)) }
    }

    /// Sends the files; calls back on the main thread with success.
    static func send(_ paths: [String], to target: Target, done: @escaping (Bool) -> Void) {
        let files = paths.filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        guard let cli = cli, isSafeTarget(target.id), !files.isEmpty else { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = run(cli, ["file", "cp"] + files + [target.id + ":"]) != nil
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// stdout when the tool exits 0, else nil.
    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// The expanded "暫存" page: drop files in, drag them out, double-click to open.
struct ShelfView: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var targeted = false
    @State private var hovered: String?
    @State private var tailTargets: [Taildrop.Target] = []

    var body: some View {
        ZStack {
            if shelf.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .medium))
                        .foregroundColor(.white.opacity(targeted ? 0.95 : 0.6))
                        .symbolEffect(.bounce, value: targeted)
                    Text("把檔案拖到這裡暫放，之後再拖出去用").font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
                }
            } else {
                HStack(alignment: .center, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items) { item in
                                tile(item).transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 22).padding(.vertical, 10)
                    }
                    // Inside the dashed frame, centred top to bottom with even gaps.
                    VStack(spacing: 6) {
                        sideButton("airdrop", image: nil, systemPrivate: true, "AirDrop 全部") { shelf.airDrop(shelf.items) }
                        if Taildrop.cli != nil { taildropMenu(shelf.items) }
                        sideButton("trash", image: nil, "清空") { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shelf.clear() } }
                    }
                    .padding(.trailing, 26)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundColor(.white.opacity(targeted ? 0.6 : 0.12))
                .padding(.horizontal, 14).padding(.vertical, 6)
        )
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { shelf.add([url]) }
                    }
                }
            }
            return true
        }
    }

    private func tile(_ item: ShelfStore.Item) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().frame(width: 44, height: 44)
            Text(item.name).font(.system(size: 10)).foregroundColor(.white.opacity(0.85))
                .lineLimit(1).truncationMode(.middle).frame(width: 66)
        }
        .frame(width: 70)
        .contentShape(Rectangle())
        // Hover: a ✕ in the corner removes just this file from the shelf (the file itself is untouched).
        .overlay(alignment: .topTrailing) {
            if hovered == item.id {
                Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundColor(.black)
                    .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.9)))
                    .contentShape(Circle())
                    .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shelf.remove(item) } }
                    .help("從暫存移除")
                    .offset(x: -4, y: -4)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { hovered = inside ? item.id : (hovered == item.id ? nil : hovered) } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("打開") { NSWorkspace.shared.open(item.url) }
            Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("AirDrop") { shelf.airDrop([item]) }
            if Taildrop.cli != nil {
                Menu("Taildrop 傳送到") {
                    if tailTargets.isEmpty { Text("沒有可傳送的裝置（Tailscale 未連線？）") }
                    ForEach(tailTargets) { t in Button(t.name) { sendTail([item], t) } }
                }
            }
            Divider()
            Button("從暫存移除") { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shelf.remove(item) } }
        }
        .help(item.path)
    }

    private func taildropMenu(_ items: [ShelfStore.Item]) -> some View {
        Menu {
            if tailTargets.isEmpty { Text("沒有可傳送的裝置（Tailscale 未連線？）") }
            ForEach(tailTargets) { t in Button("傳送全部到 \(t.name)") { sendTail(items, t) } }
        } label: {
            buttonFace("point.3.connected.trianglepath.dotted", image: Self.tailscaleIcon)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .help("Taildrop（Tailscale）")
        .onAppear(perform: loadTargets)
    }

    private func loadTargets() {
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Taildrop.targets()
            DispatchQueue.main.async { tailTargets = t }
        }
    }

    private func sendTail(_ items: [ShelfStore.Item], _ t: Taildrop.Target) {
        Taildrop.send(items.map(\.path), to: t) { ok in
            NoticeCenter.shared.post(IslandNotice(icon: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                                  tint: ok ? .green : .orange, title: "Taildrop",
                                                  detail: ok ? "已傳送 \(items.count) 個檔案到 \(t.name)" : "傳送到 \(t.name) 失敗",
                                                  trailing: ok ? "✓" : "!"))
        }
    }

    private func sideButton(_ icon: String, image: NSImage?, systemPrivate: Bool = false, _ label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) { buttonFace(icon, image: image, systemPrivate: systemPrivate) }
            .buttonStyle(.plain)
            .help(label)
    }

    /// A white glyph, like the trash button: an SF Symbol, or a template image (Tailscale's dots).
    private func buttonFace(_ icon: String, image: NSImage?, systemPrivate: Bool = false) -> some View {
        Group {
            if systemPrivate {
                // The system's own glyph (as in Control Center) that is not in the public symbol set, e.g. AirDrop.
                // shortcut: underscored SwiftUI API; if a macOS drops it, swap in a public symbol.
                Image(_internalSystemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            } else if let img = image {
                Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high)
                    .foregroundColor(.white).frame(width: 24, height: 24)   // the icon has wide margins around its marks
            } else {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            }
        }
        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.12))).contentShape(Circle())
    }

    /// Tailscale's dots in white, taken at run time from the installed app's icon (nothing of theirs is bundled).
    static let tailscaleIcon: NSImage? = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"].lazy
        .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        .flatMap { glyph(fromIcon: NSWorkspace.shared.icon(forFile: $0.path)) }

    /// Keeps only an icon's light marks (its dark tile becomes transparent) as a template image.
    static func glyph(fromIcon icon: NSImage, size: Int = 64) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let px = rep.bitmapData else { return nil }
        var any = false
        for i in 0..<(size * size) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2]), a = Double(px[i * 4 + 3])
            // How white (not just bright): the lowest channel, un-premultiplied. A coloured tile (AirDrop's blue)
            // drops out; grey marks stay half see-through, as in the original.
            let white = a > 0 ? min(r, g, b) / a : 0
            let keep = white > 0.28 ? min(1, (white - 0.28) / 0.5) * a / 255 : 0
            px[i * 4] = 255; px[i * 4 + 1] = 255; px[i * 4 + 2] = 255   // premultiplied white × keep below
            px[i * 4 + 3] = UInt8(keep * 255)
            px[i * 4] = UInt8(keep * 255); px[i * 4 + 1] = UInt8(keep * 255); px[i * 4 + 2] = UInt8(keep * 255)
            if keep > 0.5 { any = true }
        }
        guard any else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }
}

/// The 暫存 page: files, plus the clipboard history and the screenshots when they are turned on in settings,
/// switched at the bottom.
struct ShelfPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var side = CommandLine.arguments.contains("--test-clipboard") ? 1 : CommandLine.arguments.contains("--test-shots") ? 2 : 0

    var body: some View {
        let options: [(value: Int, label: String)] = [(0, "檔案")]
            + (settings.clipboardHistory ? [(1, "剪貼簿")] : []) + (settings.screenshotShelf ? [(2, "截圖")] : [])
        let shown = options.contains { $0.value == side } ? side : 0
        if options.count > 1 {
            VStack(spacing: 2) {
                switch shown {
                case 1: ClipboardView()
                case 2: ScreenshotView()
                default: ShelfView()
                }
                HStack(spacing: 10) {
                    if options.count > 1 {
                        // Bound to what is shown: a side turned off in settings falls back to 檔案, selected too.
                        IslandSegmented(selection: Binding(get: { shown }, set: { side = $0 }), options: options, compact: true)
                            .frame(width: CGFloat(options.count) * 60)
                    }
                }
                .padding(.bottom, 10)   // the same air below as the page has elsewhere
            }
        } else {
            ShelfView()
        }
    }
}
