import Foundation

/// What the user chose for a permission request.
enum ApprovalDecision: String, Sendable {
    case allow, deny
    /// No decision: Claude Code falls back to its normal terminal prompt.
    case terminal
}

/// A permission request as sent by the Claude Code `PermissionRequest` hook (only the fields we use).
struct ApprovalRequest: Equatable, Sendable {
    let sessionId: String
    let cwd: String
    let tool: String
    /// One line for the capsule ("npm test", "Foo.swift").
    let summary: String
    /// Longer text for the card (a whole command, capped).
    let detail: String
    /// The card shows the whole input (nothing cut off): only then can it be allowed from the island.
    var complete = true
    /// The one-line summary is the input itself, in full (not the agent's own description of it): only then can the
    /// collapsed island's ✓ allow it without opening the card.
    var summaryIsInput = true

    /// What a file edit writes, line by line (Write / Edit / MultiEdit), for the card to show before allowing.
    var changes: [Change] = []
    /// A question the agent asks you (AskUserQuestion): question and option lines, answered in the terminal.
    var question: [String] = []
    var isQuestion: Bool { tool == "AskUserQuestion" }

    struct Change: Equatable, Sendable {
        enum Kind: Sendable { case removed, added, note }
        let kind: Kind
        let text: String
    }

    /// Longest detail the card shows in full (3 lines of its monospaced text).
    static let cardLimit = 120
    /// An edit is reviewable on the card (scrolling) up to this size; bigger ones go to the terminal.
    static let changeLineLimit = 80
    static let changeCharLimit = 4000

    static let maxInputBytes = 256 * 1024

    /// Parses the hook's stdin JSON. Returns nil for anything that is not an object with a tool name.
    static func parse(_ data: Data) -> ApprovalRequest? {
        guard data.count <= maxInputBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool_name"] as? String, !tool.isEmpty, tool.count <= 100 else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let d = describe(tool: tool, input: input)
        return ApprovalRequest(
            sessionId: (obj["session_id"] as? String).map { String($0.prefix(100)) } ?? "",
            cwd: (obj["cwd"] as? String).map { String($0.prefix(1024)) } ?? "",
            tool: tool, summary: d.summary, detail: d.detail, complete: d.complete, summaryIsInput: d.summaryIsInput,
            changes: d.changes, question: tool == "AskUserQuestion" ? questionLines(input) : [])
    }

    /// The one detail worth showing for each kind of tool; nothing else from the input is displayed.
    static func describe(tool: String, input: [String: Any])
        -> (summary: String, detail: String, complete: Bool, summaryIsInput: Bool, changes: [Change]) {
        // What is shown must be what gets run: no hidden characters, no padding that pushes the rest out of view.
        func visible(_ s: String) -> String {
            let shown = String(String.UnicodeScalarView(s.unicodeScalars.map { u -> Unicode.Scalar in
                switch u.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: return " "   // \n \r \t, bidi overrides, zero-width
                default: return u
                }
            }))
            return shown.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        func clip(_ s: String, _ n: Int) -> String { String(s.prefix(n)) }
        let limit = ApprovalRequest.cardLimit
        func whole(_ v: String) -> (detail: String, complete: Bool) { (clip(v, 400), v.count <= limit) }
        if let raw = input["command"] as? String {
            let cmd = visible(raw), w = whole(cmd)
            // Claude Code's Bash tool sends a plain-language `description`; a long command's first 40 characters
            // rarely say what it does (often just a variable assignment).
            if let d = input["description"] as? String, !visible(d).isEmpty { return (clip(visible(d), 60), w.detail, w.complete, false, []) }
            return ("\(tool): \(clip(cmd, 40))", w.detail, w.complete, cmd.count <= 40, [])
        }
        if let raw = input["file_path"] as? String {
            let path = visible(raw), name = clip(visible(URL(fileURLWithPath: raw).lastPathComponent), 40), w = whole(path)
            // Read: the path is all of it. Write/Edit/MultiEdit: what they write is shown line by line, and can be
            // allowed only when all of it fits the card; anything else in the input keeps it in the terminal.
            if Set(input.keys).isSubset(of: ["file_path", "limit", "offset"]) {
                return ("\(tool): \(name)", w.detail, w.complete, false, [])   // the name alone does not say where
            }
            let ch = changes(input)
            let lines = ch?.count ?? 0, chars = ch?.reduce(0) { $0 + $1.text.count } ?? 0
            let reviewable = ch != nil && lines <= ApprovalRequest.changeLineLimit && chars <= ApprovalRequest.changeCharLimit
                && (ch ?? []).allSatisfy { $0.text.count <= 300 }   // a longer line would be cut on the card
            let shown = Array((ch ?? []).prefix(ApprovalRequest.changeLineLimit)).map { Change(kind: $0.kind, text: clip($0.text, 300)) }
            return ("\(tool): \(name)", w.detail, w.complete && reviewable, false, shown)
        }
        for key in ["url", "pattern", "query"] {
            if let raw = input[key] as? String {
                let v = visible(raw), w = whole(v)
                return ("\(tool): \(clip(v, 40))", w.detail, w.complete, v.count <= 40, [])
            }
        }
        if tool == "AskUserQuestion", let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String {
            return (clip(visible(q), 60), clip(visible(q), 400), false, false, [])   // answered in the terminal
        }
        // Other tools (MCP, Task…): their input is not shown at all, so the island never allows them on its own.
        let name = clip(visible(tool), 60)
        return (name, name, input.isEmpty, input.isEmpty, [])
    }

    /// "Q: …" then "・option — description" lines, each made visible and capped.
    static func questionLines(_ input: [String: Any]) -> [String] {
        let qs = input["questions"] as? [[String: Any]] ?? []
        var out: [String] = []
        for q in qs.prefix(4) {
            if let text = q["question"] as? String { out.append(String(showLine(text).prefix(200))) }
            for o in (q["options"] as? [[String: Any]] ?? []).prefix(6) {
                let label = showLine(o["label"] as? String ?? "")
                let desc = (o["description"] as? String).map { " — " + showLine($0) } ?? ""
                out.append("・" + String((label + desc).prefix(200)))
            }
        }
        return out
    }

    /// The lines an edit removes and adds; nil when the input has anything we would not show (then: terminal only).
    static func changes(_ input: [String: Any]) -> [Change]? {
        func lines(_ s: String, _ kind: Change.Kind) -> [Change] {
            s.components(separatedBy: "\n").map { Change(kind: kind, text: showLine($0)) }
        }
        let keys = Set(input.keys)
        if keys.isSubset(of: ["file_path", "content"]), let content = input["content"] as? String {              // Write
            return [Change(kind: .note, text: "寫入整個檔案")] + lines(content, .added)
        }
        if keys.isSubset(of: ["file_path", "old_string", "new_string", "replace_all"]),                               // Edit
           let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            let all = (input["replace_all"] as? Bool) == true ? [Change(kind: .note, text: "取代檔案中所有相同內容")] : []
            return all + lines(old, .removed) + lines(new, .added)
        }
        if keys.isSubset(of: ["file_path", "edits"]), let edits = input["edits"] as? [[String: Any]], !edits.isEmpty {  // MultiEdit
            var out: [Change] = []
            for (i, e) in edits.enumerated() {
                guard let sub = changes(e.merging(["file_path": ""]) { a, _ in a }) else { return nil }
                out += [Change(kind: .note, text: "第 \(i + 1) 處")] + sub
            }
            return out
        }
        return nil
    }

    /// One line as it will be written, with nothing hidden: tabs as spaces, other control / bidi / zero-width
    /// characters as a visible "·" (they would otherwise change what you think you are reading).
    static func showLine(_ s: String) -> String {
        let scalars = s.unicodeScalars.flatMap { u -> [Unicode.Scalar] in
            if u == "\t" { return Array("    ".unicodeScalars) }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return ["·"]
            default: return [u]
            }
        }
        var line = String(String.UnicodeScalarView(scalars))
        while line.last == " " { line.removeLast() }
        return line
    }
}

/// Wire format between the hook process and the app, and the hook's stdout.
enum ApprovalWire {
    /// App → hook: a single JSON line.
    static func reply(_ d: ApprovalDecision) -> Data { Data("{\"decision\":\"\(d.rawValue)\"}\n".utf8) }

    static func parseReply(_ data: Data) -> ApprovalDecision? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["decision"] as? String else { return nil }
        return ApprovalDecision(rawValue: s)
    }

    /// What the hook prints for Claude Code. `nil` = print nothing (normal permission flow).
    static func hookOutput(for d: ApprovalDecision) -> Data? {
        let decision: [String: Any]
        switch d {
        case .allow: decision = ["behavior": "allow"]
        case .deny: decision = ["behavior": "deny", "message": "Denied from GrindIsland"]
        case .terminal: return nil
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: out)
    }

    /// `~/Library/Application Support/GrindIsland/approval.sock`, built from fixed names only.
    static func socketPath(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/GrindIsland/approval.sock"
    }
}
