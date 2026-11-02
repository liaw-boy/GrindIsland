import SwiftUI

public struct AgentListView: View {
    @ObservedObject private var monitor = AgentMonitor.shared
    @EnvironmentObject private var geom: NotchGeometry   // this display's island
    @ObservedObject private var settings = AppSettings.shared
    @State private var showUsage = CommandLine.arguments.contains("--test-usage")   // switch for screenshots

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    /// One look per session, handed out by project folder (not by agent kind).
    private var looks: [String: CatLook] {
        CatLook.assign(monitor.sessions.map { (id: $0.id, seed: $0.cwd.isEmpty ? $0.name : $0.cwd) })
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 4) {
            if showUsage && settings.usageStats {
                UsageView().padding(.horizontal, geom.contentEdge)
            } else if monitor.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        let looks = looks
                        ForEach(monitor.sessions) { session in
                            AgentCard(session: session, look: looks[session.id] ?? CatLook.all[0])
                        }
                    }
                    .padding(.horizontal, geom.contentEdge)
                    .padding(.top, 4)
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                Text("共 \(monitor.sessions.count) 個本機 Agent")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                if settings.usageStats {
                    // Cards | today's token use (setting 功能 › AI 用量統計).
                    IslandSegmented(selection: $showUsage, options: [(false, "卡片"), (true, "用量")], compact: true)
                        .frame(width: 110)
                }
                Button(action: { monitor.scan() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8.5))
                        Text("重新掃描")
                            .font(.system(size: 9.5))
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, geom.contentEdge + 4)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // never taller than the space below the top bar
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            CatAvatar(state: .idle, look: CatLook.all[0])
                .frame(width: 56, height: 56)
            Text("目前沒有執行中的 Agent")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentCard: View {
    let session: LocalAgentSession
    let look: CatLook
    @ObservedObject private var monitor = AgentMonitor.shared
    @State private var pulse = false

    private var waiting: Bool { session.state == .waitingApproval || pending != nil }
    private var pending: AgentMonitor.PendingApproval? { monitor.pendingApproval(for: session) }

    private var accent: Color {
        switch (waiting ? AgentState.waitingApproval : session.state) {
        case .waitingApproval: return Color.orange
        case .working: return Color(red: 0.4, green: 0.87, blue: 0.6)
        default: return Color.white.opacity(0.4)
        }
    }

    private var statusText: String {
        switch (waiting ? AgentState.waitingApproval : session.state) {
        case .waitingApproval: return "喵!等你授權"
        case .working: return "工作中"
        case .completed: return "完成了"
        case .idle: return "休息中"
        }
    }

    private var detail: String {
        if waiting { return session.prompt ?? "permission prompt" }
        return session.task
    }

    /// Working / waiting: the tool in use; otherwise the AI title, falling back to the folder.
    private var infoLine: String {
        if waiting { return session.extra.currentTool ?? session.prompt ?? "permission prompt" }
        if session.state == .working, let tool = session.extra.currentTool { return tool }
        if let title = session.extra.title { return title }
        return detail.isEmpty ? session.kind : detail
    }

    private func startPulse() {
        guard waiting else { pulse = false; return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }

    private func approvalPill(_ title: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tokenText(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM tokens", Double(n) / 1_000_000)
            : n >= 1000 ? String(format: "%.1fk tokens", Double(n) / 1000) : "\(n) tokens"
    }

    var body: some View {
        HStack(spacing: 9) {
            CatAvatar(state: waiting ? .waitingApproval : session.state, look: look)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle().fill(accent).frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(accent)
                }

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(infoLine) · \(formatElapsed(session.statusSince))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                if let p = pending {
                    Text(p.request.detail)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(p.request.complete ? 3 : 2)
                    if !p.request.changes.isEmpty { ChangePreview(lines: p.request.changes) }
                    if !p.request.complete {
                        Text("內容太長，島上看不完整：請回終端機確認").font(.system(size: 9, weight: .semibold)).foregroundColor(.orange)
                    }
                    HStack(spacing: 5) {
                        approvalPill("拒絕", Color(red: 0.95, green: 0.35, blue: 0.35)) { monitor.resolve(p, .deny) }
                        // Allowing what is not fully shown would approve something unseen.
                        if p.request.complete {
                            approvalPill("允許", Color(red: 0.3, green: 0.8, blue: 0.45)) { monitor.resolve(p, .allow) }
                        }
                        approvalPill("回終端機", Color.white.opacity(0.25)) { monitor.resolve(p, .terminal) }
                    }
                    .padding(.top, 2)
                } else if session.extra.tokens > 0 {
                    Text(tokenText(session.extra.tokens))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
            }

            Spacer(minLength: 0)

            Button(action: { monitor.focusHost(of: session) }) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundColor(waiting ? Color.orange : .white.opacity(0.45))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.07))   // no tint when waiting: the pulsing orange border is the cue
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(waiting ? Color.orange.opacity(pulse ? 0.7 : 0.3) : Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: waiting ? Color.orange.opacity(pulse ? 0.4 : 0.1) : .clear, radius: 8)
        .onAppear { startPulse() }
        .onChange(of: waiting) { _, _ in startPulse() }
    }
}

/// What an edit removes (red, −) and adds (green, +), scrollable; every line wraps so nothing is cut off.
struct ChangePreview: View {
    let lines: [ApprovalRequest.Change]
    /// Off for rendering to an image (ImageRenderer does not draw scroll views).
    var scrolls = true
    var fontSize: CGFloat = 8.5
    var maxHeight: CGFloat = 54

    var body: some View {
        if scrolls {
            ScrollView(.vertical, showsIndicators: true) { rows }
                .frame(maxHeight: maxHeight)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
        } else {
            rows.background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
        }
    }

    private var rows: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .top, spacing: 3) {
                        Text(c.kind == .removed ? "−" : c.kind == .added ? "+" : "›")
                        Text(c.text.isEmpty ? " " : c.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: fontSize, weight: c.kind == .note ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(c.kind == .removed ? Color(red: 1, green: 0.55, blue: 0.55)
                                     : c.kind == .added ? Color(red: 0.55, green: 0.92, blue: 0.62) : .white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(c.kind == .removed ? Color.red.opacity(0.1) : c.kind == .added ? Color.green.opacity(0.08) : .clear)
                }
            }
    }
}

/// A permission request opened from the collapsed island's ✓: the island grows and shows all of it in large type,
/// with the answer buttons under it. "允許" only when everything was shown.
struct ApprovalReviewView: View {
    let item: AgentMonitor.PendingApproval
    @ObservedObject private var monitor = AgentMonitor.shared
    @EnvironmentObject private var geom: NotchGeometry   // this display's island

    var body: some View {
        let r = item.request
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundColor(.orange)
                Text(r.tool).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                if !r.cwd.isEmpty {
                    Text(URL(fileURLWithPath: r.cwd).lastPathComponent).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Text(r.summary).font(.system(size: 11)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
            }
            .font(.system(size: 12))
            Group {
                if r.isQuestion {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(r.question.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: line.hasPrefix("・") ? 12 : 13.5, weight: line.hasPrefix("・") ? .regular : .semibold))
                                    .foregroundColor(.white.opacity(line.hasPrefix("・") ? 0.8 : 1))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                } else if r.changes.isEmpty {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(r.detail).font(.system(size: 12, design: .monospaced)).foregroundColor(.white.opacity(0.9))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.detail).font(.system(size: 10.5, design: .monospaced)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                        ChangePreview(lines: r.changes, fontSize: 11, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if r.isQuestion {
                Text("Agent 在問你問題，請到終端機選擇").font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
            } else if !r.complete {
                Text("內容太長，島上看不完整：請回終端機確認").font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
            }
            HStack(spacing: 8) {
                if r.isQuestion {
                    answer("到終端機回答", Color(red: 0.95, green: 0.6, blue: 0.2)) {
                        monitor.resolve(item, .terminal)
                        if let s = monitor.sessions.first(where: { $0.sessionId == r.sessionId }) { monitor.focusHost(of: s) }
                    }
                } else {
                answer("拒絕", Color(red: 0.95, green: 0.35, blue: 0.35)) { monitor.resolve(item, .deny) }
                if r.complete { answer("允許", Color(red: 0.3, green: 0.8, blue: 0.45)) { monitor.resolve(item, .allow) } }
                answer("回終端機", Color.white.opacity(0.22)) { monitor.resolve(item, .terminal) }
                }
                Spacer()
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { geom.reviewingApproval = nil } } label: {
                    Text("稍後").font(.system(size: 11)).foregroundColor(.white.opacity(0.5)).padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, geom.contentEdge).padding(.bottom, 10).padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func answer(_ title: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            action()
        } label: {
            Text(title).font(.system(size: 12.5, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(color)).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
