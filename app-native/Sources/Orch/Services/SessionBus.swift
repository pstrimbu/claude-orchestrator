import Foundation

/// File-based coordination surface for running sessions, so a lead session, a
/// script, or the user can drive any session the same way regardless of which
/// agent CLI it runs.
///
///   .orch/status.json      — this session's live state (busy/idle, branch, inbox depth)
///   .orch/inbox/*.md       — messages to type into the session, oldest name first
///   .orch/inbox/delivered/ — consumed messages, kept for diagnosis
///   ~/.config/orch/sessions/<name>.json — registry entry {name, path, pid}
///
/// Delivery only happens when the agent is sitting at its prompt and the human
/// isn't typing: the PTY has been quiet, no recent keystrokes, nothing half-typed,
/// and the previous delivery has produced output and gone quiet again.
final class SessionBus {
    let name: String
    let projectPath: String
    private let orchDir: String
    private let inboxDir: String
    private let deliveredDir: String
    private let statusPath: String
    private let registryPath: String

    /// Quiet PTY time before the agent counts as idle. Both CLIs animate a spinner
    /// while working, so sustained silence means "waiting at the prompt".
    static let idleQuiet: TimeInterval = 5
    /// Don't type over a human: hold delivery this long after their last keystroke.
    static let humanQuiet: TimeInterval = 15

    private var lastDeliveredAt: Date?

    init(projectPath: String, orchDir: String) {
        self.projectPath = projectPath
        self.name = (projectPath as NSString).lastPathComponent
        self.orchDir = orchDir
        self.inboxDir = orchDir + "/inbox"
        self.deliveredDir = orchDir + "/inbox/delivered"
        self.statusPath = orchDir + "/status.json"
        let sessionsDir = NSHomeDirectory() + "/.config/orch/sessions"
        self.registryPath = sessionsDir + "/\(name).json"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: deliveredDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        writeJSON(["name": name, "path": projectPath,
                   "pid": Int(ProcessInfo.processInfo.processIdentifier)], to: registryPath)
    }

    struct Snapshot {
        var running: Bool
        var ptyQuiet: TimeInterval
        var humanQuiet: TimeInterval
        var inputPending: Bool       // the human has something half-typed
        var blockingPrompt: Bool     // a trust/confirm dialog is on screen
        var agent: String
        var model: String?
        var branch: String?
        var lastCommand: String
        var account: String?
        var limitedUntil: Date?
    }

    /// Called once a second from the status timer. Returns a message to deliver,
    /// if the session is ready for one; the caller types it and calls `delivered`.
    func tick(_ s: Snapshot) -> (text: String, file: String)? {
        let idle = s.running && s.ptyQuiet >= Self.idleQuiet
        let pending = inboxFiles()
        // A dialog on screen (trust prompt, a question the agent asked) reads as
        // quiet, but nobody else can answer it: report it as its own state.
        let limited = (s.limitedUntil ?? .distantPast) > Date()
        let state = !s.running ? "exited"
            : limited ? "limited"
            : (idle ? (s.blockingPrompt ? "prompt" : "idle") : "busy")
        // Why a pending message isn't being typed in — shown in status.json so a
        // stuck inbox is diagnosable from outside.
        var hold: String? = nil
        if !pending.isEmpty {
            if !s.running { hold = "session not running" }
            else if limited { hold = "account limited" }
            else if !idle { hold = "agent busy" }
            else if s.blockingPrompt { hold = "prompt on screen" }
            else if s.inputPending { hold = "text typed but not sent" }
            else if s.humanQuiet < Self.humanQuiet { hold = "you typed recently" }
            else if let at = lastDeliveredAt, Date().timeIntervalSince(at) <= s.ptyQuiet {
                hold = "waiting for a reply to the last message"
            }
        }
        writeStatus(s, state: state, pending: pending.count, hold: hold)
        guard hold == nil, let next = pending.first else { return nil }
        guard let text = try? String(contentsOfFile: inboxDir + "/" + next, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            moveToDelivered(next)   // empty or unreadable: don't wedge the queue
            return nil
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), next)
    }

    /// Startup dialogs where an injected Enter picks the default — Claude's
    /// folder-trust prompt defaults to "No, exit". Never deliver into one; the
    /// message waits until a human answers it.
    static func showsBlockingPrompt(_ lettersTail: String) -> Bool {
        let markers = ["trustthisfolder", "trustthecontents", "noexit", "entertoconfirm",
                       "cannotusethebackgroundserver", "runwithoutdaemon"]
        let tail = String(lettersTail.suffix(1500))
        return markers.contains { tail.contains($0) }
    }

    /// Lowercased letters only: TUIs position words with cursor moves rather
    /// than spaces, so this is the stable form to match prompt text against.
    static func letters(_ s: String) -> String {
        var out = ""
        var inEscape = false
        for ch in s.unicodeScalars {
            if inEscape {
                if (ch.value >= 0x40 && ch.value <= 0x7e) && ch != "[" { inEscape = false }
                continue
            }
            if ch == "\u{1b}" { inEscape = true; continue }
            if CharacterSet.letters.contains(ch) { out.unicodeScalars.append(ch) }
        }
        return out.lowercased()
    }

    /// Queue a message from orch itself (same path as orch-send).
    func enqueue(_ text: String) {
        let name = String(format: "%@-orch-%d.md", Self.stamp(), Int.random(in: 1000...9999))
        let tmp = inboxDir + "/" + name + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: Data((text + "\n").utf8)) {
            _ = rename(tmp, inboxDir + "/" + name)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// The CLIs' own "you're out" messages (Claude: "…usage limit reached…" /
    /// "You've hit your limit"; Codex: "You've hit your usage limit"), matched
    /// in the last few hundred letters of output so a model merely *discussing*
    /// limits earlier in a long reply doesn't trip it.
    static func showsLimitMessage(_ lettersTail: String) -> Bool {
        let tail = String(lettersTail.suffix(400))
        return ["usagelimitreached", "youvehityourlimit", "youvehityourusagelimit",
                "limitreachedresets", "limitwillreset"].contains { tail.contains($0) }
    }

    func delivered(_ file: String) {
        lastDeliveredAt = Date()
        moveToDelivered(file)
    }

    /// The registry entry stays: a closed session with undelivered messages must
    /// stay visible (orch-sessions shows it as exited, and ages it out).
    func shutdown() {
        writeJSON(["name": name, "path": projectPath, "state": "exited",
                   "updated_at": ISO8601DateFormatter().string(from: Date())], to: statusPath)
    }

    // MARK: - Files

    /// Pending messages, oldest first. Writers drop `*.tmp` and rename, so only
    /// complete `.md`/`.txt` files are picked up.
    private func inboxFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inboxDir)) ?? []
        return names.filter { $0.hasSuffix(".md") || $0.hasSuffix(".txt") }.sorted()
    }

    private func moveToDelivered(_ file: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.moveItem(atPath: inboxDir + "/" + file,
                                          toPath: deliveredDir + "/\(stamp)-\(file)")
    }

    private func writeStatus(_ s: Snapshot, state: String, pending: Int, hold: String? = nil) {
        var obj: [String: Any] = [
            "name": name,
            "path": projectPath,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "agent": s.agent,
            "state": state,
            "idle_seconds": Int(s.ptyQuiet.isFinite ? s.ptyQuiet : -1),
            "inbox_pending": pending,
            "last_command": String(s.lastCommand.prefix(200)),
        ]
        if let m = s.model { obj["model"] = m }
        if let b = s.branch { obj["branch"] = b }
        if let a = s.account { obj["account"] = a }
        if let h = hold { obj["inbox_hold"] = h }
        if let u = s.limitedUntil, u > Date() {
            obj["limited_until"] = ISO8601DateFormatter().string(from: u)
        }
        obj["updated_at"] = ISO8601DateFormatter().string(from: Date())
        writeJSON(obj, to: statusPath)
    }

    private func writeJSON(_ obj: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = path + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: data) {
            _ = rename(tmp, path)
        }
    }
}
