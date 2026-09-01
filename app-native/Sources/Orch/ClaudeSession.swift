import Foundation

class ClaudeSession {
    private var fileHandle: FileHandle?
    private(set) var childPid: pid_t = 0
    private(set) var running = false
    /// The session id, when we know it authoritatively rather than by discovery:
    /// minted here and forced via --session-id for a new session, or handed to us
    /// for --resume. Nil for --continue, where Claude picks the most recent
    /// session itself and the id has to be found from the transcript instead.
    private(set) var sessionId: String?
    private var mode: SessionMode
    private let projectPath: String
    private let agent: Agent
    private let model: String?
    private let remoteControl: Bool
    private let remoteName: String?
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var lastActivity = Date()
    var masterFd: Int32 = -1

    // Serial queue for PTY writes. Writing to the PTY master on the main thread
    // can block when claude isn't draining stdin fast enough (busy tool call,
    // big output) — which freezes the UI. Keep writes off the main thread.
    private let writeQueue = DispatchQueue(label: "orch.pty.write", qos: .userInitiated)

    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(projectPath: String, cols: Int, rows: Int, mode: SessionMode,
         agent: Agent = .claude, model: String? = nil,
         remoteControl: Bool = false, remoteName: String? = nil) {
        self.projectPath = projectPath
        self.cols = cols
        self.rows = rows
        self.mode = mode
        self.agent = agent
        self.model = model
        self.remoteControl = remoteControl
        self.remoteName = remoteName
    }

    /// Where Claude Code drops its own status JSON for us. See `statusSettings()`.
    static func statusFile(projectPath: String) -> String { projectPath + "/.orch/statusline.json" }
    static func subagentFile(projectPath: String) -> String { projectPath + "/.orch/subagents.json" }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Settings injected via `--settings`, scoped to this spawned process only.
    ///
    /// Claude Code pipes a documented JSON blob (context window, cost, model, PR
    /// state) to a statusLine command after every assistant message and after
    /// `/compact` finishes. We ask it to dump that JSON to a file and print
    /// nothing — its own status row stays empty and orch renders the values in
    /// the native bar instead.
    ///
    /// This replaces parsing the session transcript, which the Claude Code docs
    /// warn is "internal to Claude Code and changes between versions, so scripts
    /// that parse these files directly can break on any release."
    ///
    /// `cat > tmp && mv -f` makes each write atomic, so our poller never reads a
    /// half-written file. The user's own statusLine (if any) is untouched: this
    /// applies only to sessions orch spawns.
    private func statusSettings() -> String? {
        func dumpTo(_ path: String) -> [String: String] {
            let tmp = shellQuote(path + ".tmp"), dst = shellQuote(path)
            return ["type": "command", "command": "cat > \(tmp) && mv -f \(tmp) \(dst)"]
        }
        let settings: [String: Any] = [
            "statusLine": dumpTo(Self.statusFile(projectPath: projectPath)),
            "subagentStatusLine": dumpTo(Self.subagentFile(projectPath: projectPath)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func spawn() {
        let binaryPath = resolveBinary()
        Log.log("using \(agent.rawValue) at: \(binaryPath)")

        let args = agent == .claude ? claudeArgs() : codexArgs()

        // Set up PTY
        var winSize = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var masterFdVar: Int32 = 0
        let pid = forkpty(&masterFdVar, nil, nil, &winSize)

        if pid < 0 {
            Log.log("forkpty failed: \(errno)")
            return
        }

        if pid == 0 {
            // Child process
            chdir(projectPath)

            // Set up environment — when launched via `open`, inherit minimal
            // launchd env. Resolve the user's login shell PATH so claude can
            // find git, node, and other tools.
            setenv("TERM", "xterm-256color", 1)
            setenv("COLUMNS", String(cols), 1)
            setenv("LINES", String(rows), 1)
            unsetenv("ANTHROPIC_API_KEY")

            // exec the agent CLI
            let cArgs = [binaryPath] + args
            let cArgsCStr = cArgs.map { strdup($0)! } + [nil]
            execvp(binaryPath, cArgsCStr)

            // If exec fails
            perror("execvp failed")
            _exit(1)
        }

        // Parent process
        self.masterFd = masterFdVar
        self.childPid = pid
        self.running = true

        let handle = FileHandle(fileDescriptor: masterFdVar, closeOnDealloc: false)
        self.fileHandle = handle

        // Read in background
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let bufferSize = 16384
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while true {
                let bytesRead = read(masterFdVar, buffer, bufferSize)
                if bytesRead <= 0 { break }

                let data = Data(bytes: buffer, count: bytesRead)
                DispatchQueue.main.async {
                    self?.lastActivity = Date()
                    self?.onData?(data)
                }
            }

            // Wait for child
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = false
                close(masterFdVar)

                // If --resume failed (e.g. the id no longer resolves), fall back to
                // --continue rather than stranding the window.
                if exitCode != 0, case .resume = self.mode {
                    self.mode = .continue_
                    self.spawn()
                    return
                }
                // If --continue failed, retry as new session
                if exitCode != 0, case .continue_ = self.mode {
                    self.mode = .new
                    self.spawn()
                    return
                }

                self.onExit?(exitCode)
            }
        }

        Log.log("session spawned, pid=\(pid), masterFd=\(masterFdVar)")
    }

    func write(_ data: String) {
        guard running, masterFd >= 0 else { return }
        let fd = masterFd
        writeQueue.async {
            data.withCString { ptr in
                let len = strlen(ptr)
                _ = Foundation.write(fd, ptr, len)
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        guard running, masterFd >= 0, !bytes.isEmpty else { return }
        let fd = masterFd
        writeQueue.async {
            bytes.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    _ = Foundation.write(fd, base, buf.count)
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard masterFd >= 0 else { return }
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        ioctl(masterFd, TIOCSWINSZ, &ws)
    }

    var idleSeconds: Int {
        Int(Date().timeIntervalSince(lastActivity))
    }

    func kill() {
        guard childPid > 0 else { return }
        running = false
        Foundation.kill(childPid, SIGTERM)
        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
        }
        childPid = 0
    }

    /// Claude Code launch args (session-id minting, --continue/--resume, remote
    /// control, and the statusLine settings orch reads its bar from).
    private func claudeArgs() -> [String] {
        var args = ["--dangerously-skip-permissions"]
        switch mode {
        case .new:
            // Mint the id and tell Claude to use it, rather than spawning and then
            // trying to work out which session we got. Pids aren't involved, so
            // this can't be fooled by pid reuse. Minted per spawn on purpose: a
            // UUID that already has a transcript would collide, so the
            // .continue_ -> .new retry below must not reuse an earlier one.
            let id = UUID().uuidString.lowercased()
            sessionId = id
            args += ["--session-id", id]
        case .continue_:
            // Claude resolves "most recent conversation here" itself; we can't
            // dictate the id, so leave it to be discovered.
            sessionId = nil
            args.append("--continue")
        case .resume(let id):
            sessionId = id
            args += ["--resume", id]
        }
        if let m = model, !m.isEmpty { args += ["--model", m] }
        // Remote Control: driveable from claude.ai/code or the Claude mobile app.
        if remoteControl {
            args.append("--remote-control")
            if let name = remoteName, !name.isEmpty { args.append(name) }
        }
        // Have Claude report its own status to us (see statusSettings()).
        if let settings = statusSettings() { args += ["--settings", settings] }
        return args
    }

    /// Codex CLI launch args, also used for LM Studio (Codex's local provider).
    /// Codex tracks its own sessions, so there's no id to mint or discover;
    /// --continue/--resume both map to `codex resume --last`.
    private func codexArgs() -> [String] {
        sessionId = nil
        var flags = ["--dangerously-bypass-approvals-and-sandbox"]
        if agent == .lmstudio { flags += ["--oss", "--local-provider", "lmstudio"] }
        if let m = model, !m.isEmpty { flags += ["-m", m] }

        switch mode {
        case .new:
            return flags
        case .continue_, .resume:
            // `resume` is a subcommand and must come first.
            return ["resume", "--last"] + flags
        }
    }

    private func resolveBinary() -> String {
        if let p = AgentTools.resolve(agent.binaryName, common: agent.commonPaths) { return p }
        fatalError("Could not find '\(agent.binaryName)' binary for \(agent.rawValue)")
    }

}
