import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import SwiftUI

/// The system permissions GrindIsland uses, their state, and what needs them (設定 › 權限).
/// Checking never asks: each check is a read of the current state.
enum Permissions {
    enum State: Equatable {
        case allowed, denied, notAsked, appNotRunning
        var label: String {
            switch self {
            case .allowed: return "已允許"
            case .denied: return "未允許"
            case .notAsked: return "用到時詢問"
            case .appNotRunning: return "對方 App 未開啟"
            }
        }
        var color: Color {
            switch self {
            case .allowed: return IslandStyleKit.on
            case .denied: return .orange
            case .notAsked, .appNotRunning: return .white.opacity(0.5)
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let icon: String
        let uses: String
        let pane: String            // System Settings › Privacy & Security anchor
        let state: () -> State
        /// Only listed when this is true (e.g. an app that not everyone has installed).
        var applies: () -> Bool = { true }
    }

    static let items: [Item] = [
        Item(id: "ax", title: "輔助使用", icon: "accessibility", uses: "由島處理音量與亮度鍵",
             pane: "Privacy_Accessibility", state: { AXIsProcessTrusted() ? .allowed : .notAsked }),
        Item(id: "screen", title: "螢幕錄製", icon: "rectangle.dashed.badge.record", uses: "螢幕錄影",
             pane: "Privacy_ScreenCapture", state: { CGPreflightScreenCaptureAccess() ? .allowed : .notAsked }),
        Item(id: "cal", title: "行事曆", icon: "calendar", uses: "行事曆分頁、會議提醒、新增行程",
             pane: "Privacy_Calendars", state: { ek(.event) }),
        Item(id: "rem", title: "提醒事項", icon: "checklist", uses: "行事曆分頁的提醒事項",
             pane: "Privacy_Reminders", state: { ek(.reminder) }),
        Item(id: "music", title: "自動化（音樂）", icon: "music.note", uses: "歌詞、播放控制、隨機與循環播放",
             pane: "Privacy_Automation", state: { automation("com.apple.Music") }),
        Item(id: "cmux", title: "自動化（cmux）", icon: "terminal", uses: "從 Agent 卡片跳到它的終端機分頁",
             pane: "Privacy_Automation", state: { automation("com.cmuxterm.app") },
             applies: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cmuxterm.app") != nil }),
        Item(id: "paste", title: "從其他 App 貼上", icon: "doc.on.clipboard", uses: "剪貼簿歷史",
             pane: "Privacy_Pasteboard", state: { paste() }),
    ]

    private static func ek(_ type: EKEntityType) -> State {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Apple Events to another app, without asking (askUserIfNeeded: false).
    private static func automation(_ bundleID: String) -> State {
        var target = AEAddressDesc()
        guard let data = bundleID.data(using: .utf8) else { return .notAsked }
        let made = data.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, data.count, &target) }
        guard made == noErr else { return .notAsked }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .appNotRunning
        default: return .notAsked
        }
    }

    private static func paste() -> State {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        default: return .notAsked
        }
    }

    /// The permissions that apply on this Mac.
    static var shown: [Item] { items.filter { $0.applies() } }

    static func open(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// 設定 › 權限: each permission, its state (refreshed every 2 s while shown) and a way to change it.
struct PermissionsPage: View {
    @State private var states: [String: Permissions.State] = [:]
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ForEach(Array(Permissions.shown.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 52) }
                    row(p)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IslandStyleKit.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(IslandStyleKit.cardLine, lineWidth: 0.5))
            Text("在系統設定允許之後，這裡幾秒內會自動更新。權限都在「系統設定 › 隱私權與安全性」，可以隨時收回；收回後用到它的功能會停下來，其他功能照常。")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { refresh(); timer = Timer.commonModeTimer(interval: 2, repeats: true) { _ in refresh() } }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: Permissions.shown.map { ($0.id, $0.state()) })
    }

    private func row(_ p: Permissions.Item) -> some View {
        let state = states[p.id] ?? .notAsked
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: p.icon).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.title).font(.system(size: 13.5, weight: .semibold))
                    if state == .allowed { Image(systemName: "checkmark.circle.fill").foregroundColor(state.color) }
                    Text(state.label).font(.system(size: 12, weight: .medium)).foregroundColor(state.color)
                }
                Text("用到的功能：\(p.uses)").font(.system(size: 11)).foregroundColor(IslandStyleKit.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("打開系統設定") { Permissions.open(p.pane) }.buttonStyle(IslandButton())
        }
        .padding(.vertical, 10)
    }
}
