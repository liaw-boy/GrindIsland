import Foundation
import Combine
import Darwin
import AppKit

public enum AgentState: String, Sendable, Codable {
    case idle
    case working
    case waitingApproval
    case completed
}

public struct LocalAgentSession: Identifiable, Sendable, Equatable {
    public let id: String
    public var pid: Int32
    public var name: String
    public var kind: String          // "Claude Code" / "Antigravity"
    public var state: AgentState
    public var task: String
    public var prompt: String?
    public var cwd: String
    public var startedAt: Date
    public var statusSince: Date
    var extra = AgentExtraInfo()
    var sessionId: String?

    public init(
        id: String,
        pid: Int32 = 0,
        name: String,
        kind: String = "Claude Code",
        state: AgentState = .idle,
        task: String = "",
        prompt: String? = nil,
        cwd: String = "",
        startedAt: Date = Date(),
        statusSince: Date = Date()
    ) {
        self.id = id
        self.pid = pid
        self.name = name
        self.kind = kind
        self.state = state
        self.task = task
        self.prompt = prompt
        self.cwd = cwd
        self.startedAt = startedAt
        self.statusSince = statusSince
    }
}

/// Watches REAL agent processes on this Mac. Nothing here is simulated.
/// - Claude Code: ~/.claude/sessions/<pid>.json (alive-checked with kill(pid,0))
/// - Antigravity CLI: running `agy` processes + recency of brain transcripts
public final class AgentMonitor: ObservableObject, @unchecked Sendable {
    public static let shared = AgentMonitor()

    @Published public var sessions: [LocalAgentSession] = []
    @Published public var priorityAlertSession: LocalAgentSession?
    /// A session that just finished working: shown for a few seconds (`doneNoticeSeconds`), then dropped.
    @Published public var doneNotice: LocalAgentSession?
    /// Permission requests received from the Claude Code hook, oldest first.
    @Published var pendingApprovals: [PendingApproval] = []
    private var approvalReplies: [UUID: (ApprovalDecision) -> Void] = [:]
    /// When each session's request was last answered from the island. The session scan keeps reporting "waiting" until
    /// Claude Code rewrites its status file, which would leave a button-less notice on screen after you pressed ✕/✓.
    private var answeredAt: [String: Date] = [:]
    private static let answeredQuietSeconds: TimeInterval = 8

    func recentlyAnswered(_ s: LocalAgentSession) -> Bool {
        guard let sid = s.sessionId, let t = answeredAt[sid] else { return false }
        return Date().timeIntervalSince(t) < Self.answeredQuietSeconds
    }
    /// How long a request waits for an answer before Claude Code's own terminal prompt takes over.
    static let approvalSeconds: TimeInterval = 90

    struct PendingApproval: Identifiable, Equatable {
        let id = UUID()
        let request: ApprovalRequest
        var arrivedAt = Date()
    }

    /// Requests already answered in the terminal: Claude Code does not stop the hook when you answer there, so the
    /// only sign is the session's status file moving on (not "waiting") after the request arrived.
    static func answeredElsewhere(_ approvals: [PendingApproval], sessions: [LocalAgentSession]) -> [PendingApproval] {
        approvals.filter { p in
            sessions.contains { $0.sessionId == p.request.sessionId && !p.request.sessionId.isEmpty
                && $0.state != .waitingApproval && $0.statusSince > p.arrivedAt }
        }
    }

    /// What the island shows as a notification: a permission request or an approval prompt (stays until handled),
    /// else a fresh "done".
    public var noticeSession: LocalAgentSession? {
        if let p = pendingApprovals.first {
            var s = sessions.first(where: { $0.sessionId == p.request.sessionId && !p.request.sessionId.isEmpty })
                ?? LocalAgentSession(id: "approval-\(p.id)", name: URL(fileURLWithPath: p.request.cwd).lastPathComponent,
                                     cwd: p.request.cwd)
            s.state = .waitingApproval
            s.prompt = p.request.summary
            return s
        }
        return visibleAlert ?? doneNotice
    }

    /// The "needs approval" alert from the session scan, minus one you just answered from the island.
    public var visibleAlert: LocalAgentSession? {
        priorityAlertSession.flatMap { recentlyAnswered($0) ? nil : $0 }
    }

    /// The pending request for a session, if any (matched by the id Claude Code sends).
    func pendingApproval(for session: LocalAgentSession) -> PendingApproval? {
        guard let sid = session.sessionId, !sid.isEmpty else { return pendingApprovals.first { "approval-\($0.id)" == session.id } }
        return pendingApprovals.first { $0.request.sessionId == sid }
    }

    func startApprovals(socketPath: String = ApprovalWire.socketPath()) {
        ApprovalServer.shared.onRequest = { [weak self] request, respond, onCancel in
            guard let self = self else { respond(.terminal); return }
            let item = PendingApproval(request: request)
            self.approvalReplies[item.id] = respond
            self.pendingApprovals.append(item)
            onCancel { [weak self] in self?.drop(item.id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.approvalSeconds) { [weak self] in
                self?.resolve(item, .terminal)
            }
        }
        ApprovalServer.shared.start(path: socketPath)
    }

    /// Answers a request (once) and removes it from the island.
    func resolve(_ item: PendingApproval, _ decision: ApprovalDecision) {
        guard let reply = approvalReplies.removeValue(forKey: item.id) else { return }
        reply(decision)
        if decision != .terminal, !item.request.sessionId.isEmpty { answeredAt[item.request.sessionId] = Date() }
        pendingApprovals.removeAll { $0.id == item.id }
    }

    /// The hook went away (answered in the terminal): forget the request without replying.
    private func drop(_ id: UUID) {
        approvalReplies.removeValue(forKey: id)
        pendingApprovals.removeAll { $0.id == id }
    }
    private static let doneNoticeSeconds: TimeInterval = 4
    private var doneNoticeTimer: Timer?

    private let transcripts = AgentTranscriptReader()
    private var scanTimer: Timer?
    private let queue = DispatchQueue(label: "com.grindisland.agent.monitor", qos: .utility)

    private init() {}

    public func start() {
        stop()
        scan()
        DispatchQueue.main.async { [weak self] in
            self?.scanTimer = Timer.commonModeTimer(interval: 1.5, repeats: true) { [weak self] _ in
                self?.scan()
            }
        }
    }

    public func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.scanTimer?.invalidate()
            self?.scanTimer = nil
        }
    }

    public func scan() {
        queue.async { [weak self] in
            guard let self = self else { return }
            var list = self.scanClaude()
            list.append(contentsOf: self.scanAntigravity())

            list.sort { a, b in
                func rank(_ s: AgentState) -> Int {
                    switch s {
                    case .waitingApproval: return 0
                    case .working: return 1
                    default: return 2
                    }
                }
                if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
                return a.name < b.name
            }
            for i in list.indices {
                if let sid = list[i].sessionId, let e = self.transcripts.info(sessionId: sid, cwd: list[i].cwd) { list[i].extra = e }
            }
            self.transcripts.forget(except: Set(list.compactMap { $0.sessionId }))
            let alert = list.first(where: { $0.state == .waitingApproval })
            DispatchQueue.main.async {
                let finished = self.sessions.first { old in
                    old.state == .working && list.first(where: { $0.id == old.id }).map { $0.state != .working && $0.state != .waitingApproval } == true
                }
                if self.sessions != list { self.sessions = list }
                self.priorityAlertSession = alert
                for p in Self.answeredElsewhere(self.pendingApprovals, sessions: list) { self.resolve(p, .terminal) }
                if var done = finished.flatMap({ f in list.first(where: { $0.id == f.id }) }) {
                    done.state = .completed
                    self.doneNotice = done
                    self.doneNoticeTimer?.invalidate()
                    self.doneNoticeTimer = Timer.commonModeTimer(interval: Self.doneNoticeSeconds, repeats: false) { [weak self] _ in
                        self?.doneNotice = nil
                    }
                }
            }
        }
    }

    private func scanClaude() -> [LocalAgentSession] {
        var list: [LocalAgentSession] = []
        let dir = ProcessInfo.processInfo.environment["GRINDISLAND_SESSIONS_DIR"] ?? (NSHomeDirectory() + "/.claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        for file in files where file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0,
                  kill(pid, 0) == 0 else { continue }

            let name = json["name"] as? String ?? "claude-\(pid)"
            let status = (json["status"] as? String ?? "idle").lowercased()
            let waitingFor = json["waitingFor"] as? String ?? ""
            let cwd = json["cwd"] as? String ?? ""
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            let started = ((json["startedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000
            let since = ((json["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000

            let state: AgentState
            var prompt: String? = nil
            if status == "waiting" || !waitingFor.isEmpty {
                state = .waitingApproval
                prompt = waitingFor.isEmpty ? "等你回覆" : waitingFor
            } else if status == "working" || status == "busy" || status == "running" {
                state = .working
            } else {
                state = .idle
            }

            list.append(LocalAgentSession(
                id: "claude-\(pid)",
                pid: pid,
                name: name,
                kind: "Claude Code",
                state: state,
                task: folder,
                prompt: prompt,
                cwd: cwd,
                startedAt: started > 0 ? Date(timeIntervalSince1970: started) : Date(),
                statusSince: since > 0 ? Date(timeIntervalSince1970: since) : Date()
            ))
            list[list.count - 1].sessionId = json["sessionId"] as? String
        }
        return list
    }

    private func scanAntigravity() -> [LocalAgentSession] {
        guard let out = Self.run("/bin/ps", ["-axo", "pid=,lstart=,comm="]) else { return [] }
        var pids: [(Int32, Date)] = []
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasSuffix("/agy") else { continue }
            let parts = s.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 7, let pid = Int32(parts[0]) else { continue }
            let dateStr = parts[1...5].joined(separator: " ")
            pids.append((pid, fmt.date(from: dateStr) ?? Date()))
        }
        if pids.isEmpty { return [] }

        // Most recent transcript write across all conversations → "is agy busy right now"
        let brain = NSHomeDirectory() + "/.gemini/antigravity-cli/brain"
        var newest = Date.distantPast
        if let convs = try? FileManager.default.contentsOfDirectory(atPath: brain) {
            for c in convs {
                let p = "\(brain)/\(c)/.system_generated/logs/transcript.jsonl"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let m = attrs[.modificationDate] as? Date, m > newest { newest = m }
            }
        }
        let busy = Date().timeIntervalSince(newest) < 20

        return pids.enumerated().map { idx, item in
            LocalAgentSession(
                id: "agy-\(item.0)",
                pid: item.0,
                name: "Antigravity \(idx + 1)",
                kind: "Antigravity",
                state: busy ? .working : .idle,
                task: "agy",
                startedAt: item.1,
                statusSince: busy ? newest : item.1
            )
        }
    }

    private static let cmuxBundleID = "com.cmuxterm.app"

    /// The cmux panel (terminal tab) a process runs in: cmux puts `CMUX_PANEL_ID` into the environment of everything
    /// started inside it, and it is also the `id` of the terminal in cmux's AppleScript dictionary. Only a
    /// well-formed UUID is accepted, because it is later written into an AppleScript.
    static func cmuxPanelID(ofProcess pid: Int32) -> String? {
        guard let out = run("/bin/ps", ["eww", "-p", "\(pid)"]),
              let range = out.range(of: #"CMUX_PANEL_ID=[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
                                    options: .regularExpression) else { return nil }
        return String(out[range].dropFirst("CMUX_PANEL_ID=".count))
    }

    /// Jump to the session's own screen. For an agent running in cmux that is its exact terminal: cmux's AppleScript
    /// `focus` selects the workspace and tab and brings the window to the front (cmux's socket cannot be used from
    /// outside cmux: its default mode only accepts processes started inside it). Otherwise the app hosting the agent is
    /// brought to the front. No keystrokes are injected.
    public func focusHost(of session: LocalAgentSession) {
        DispatchQueue.global(qos: .userInitiated).async {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.cmuxBundleID).first != nil,
               let panel = Self.cmuxPanelID(ofProcess: session.pid) {
                let source = """
                tell application "cmux"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with term in terminals of t
                                if (id of term as text) is "\(panel)" then
                                    focus term
                                    return "focused"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "not found"
                """
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
                if result == "focused" {
                    DispatchQueue.main.async {
                        NSRunningApplication.runningApplications(withBundleIdentifier: Self.cmuxBundleID).first?
                            .activate(options: [.activateAllWindows])
                    }
                    NSLog("GrindIsland: jumped to the cmux terminal of pid %d", session.pid)
                    return
                }
                NSLog("GrindIsland: cmux jump did not work (%@): %@", result ?? "no result", error?.description ?? "-")
            }
            if Self.focusTerminalTab(of: session.pid) { return }
            Self.activateHostApp(of: session.pid)
        }
    }

    /// Other terminals that can be told which tab to show: Terminal and iTerm2 find it by the agent's tty (AppleScript),
    /// WezTerm by its pane id (its own `wezterm cli`). Terminals without such a hook (Ghostty, Warp, IDEs…) are only
    /// brought to the front by `activateHostApp`.
    static func focusTerminalTab(of pid: Int32) -> Bool {
        guard let host = hostApp(of: pid)?.bundleIdentifier else { return false }
        switch host {
        case "com.apple.Terminal", "com.googlecode.iterm2":
            guard let tty = tty(of: pid) else { return false }
            let source = host == "com.apple.Terminal" ? """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "focused"
                            end if
                        end repeat
                    end repeat
                end tell
                return "not found"
                """ : """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "focused"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "not found"
                """
            var error: NSDictionary?
            return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue == "focused"
        case "com.github.wez.wezterm":
            guard let pane = envValue("WEZTERM_PANE", ofProcess: pid, pattern: "[0-9]{1,6}"),
                  let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) else { return false }
            let cli = app.appendingPathComponent("Contents/MacOS/wezterm").path
            guard FileManager.default.isExecutableFile(atPath: cli), run(cli, ["cli", "activate-pane", "--pane-id", pane]) != nil else { return false }
            DispatchQueue.main.async { NSRunningApplication.runningApplications(withBundleIdentifier: host).first?.activate() }
            return true
        default:
            return false
        }
    }

    /// The controlling terminal of a process, as "/dev/ttys012"; only that exact shape (it goes into an AppleScript).
    static func tty(of pid: Int32) -> String? {
        guard let out = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return validTTY(out)
    }

    static func validTTY(_ s: String) -> String? {
        s.range(of: #"^ttys?[0-9]{1,4}$"#, options: .regularExpression) != nil ? "/dev/" + s : nil
    }

    /// One environment variable of a process, only if its value matches `pattern` (it is passed on to other tools).
    static func envValue(_ name: String, ofProcess pid: Int32, pattern: String) -> String? {
        guard let out = run("/bin/ps", ["eww", "-p", "\(pid)"]),
              let range = out.range(of: "\(name)=\(pattern)(?=\\s|$)", options: .regularExpression) else { return nil }
        return String(out[range].dropFirst(name.count + 1))
    }

    /// The first regular app up the parent chain (the terminal or IDE the agent runs in).
    static func hostApp(of startPid: Int32) -> NSRunningApplication? {
        var pid = startPid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            guard let out = run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"]),
                  let ppid = Int32(out.trimmingCharacters(in: .whitespacesAndNewlines)), ppid > 1 else { return nil }
            pid = ppid
        }
        return nil
    }

    /// Fallback: walk up the parent processes to the first regular app (the terminal / IDE) and activate it.
    private static func activateHostApp(of startPid: Int32) {
        var pid = startPid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                DispatchQueue.main.async { app.activate(options: [.activateAllWindows]) }
                return
            }
            guard let out = run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"]),
                  let ppid = Int32(out.trimmingCharacters(in: .whitespacesAndNewlines)), ppid > 1 else { return }
            pid = ppid
        }
    }

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
        // A failed tool (e.g. wezterm with a stale pane) is not a success.
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}

public func formatElapsed(_ since: Date) -> String {
    let s = max(Int(Date().timeIntervalSince(since)), 0)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d"
}
