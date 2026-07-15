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
         remoteControl: Bool = false, remoteName: String? = nil) {
        self.projectPath = projectPath
        self.cols = cols
        self.rows = rows
        self.mode = mode
        self.remoteControl = remoteControl
        self.remoteName = remoteName
    }

    func spawn() {
        let claudePath = resolveClaudePath()
        Log.log("using claude at: \(claudePath)")

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

        // Remote Control: launch this session with `--remote-control [name]` so it
        // can be driven from claude.ai/code or the Claude mobile app. Claude prints
        // a QR code + session URL to the terminal on startup.
        if remoteControl {
            args.append("--remote-control")
            if let name = remoteName, !name.isEmpty { args.append(name) }
        }

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

            // exec claude
            let cArgs = [claudePath] + args
            let cArgsCStr = cArgs.map { strdup($0)! } + [nil]
            execvp(claudePath, cArgsCStr)

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

    private func resolveClaudePath() -> String {
        // Try which via shell
        let attempts = ["bash -lc \"which claude\"", "zsh -lc \"which claude\""]
        for cmd in attempts {
            if let path = shell(cmd)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, !path.contains("not found") {
                return path
            }
        }

        // Check common paths
        let common = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for p in common {
            if FileManager.default.fileExists(atPath: p) { return p }
        }

        fatalError("Could not find 'claude' binary")
    }

    private func shell(_ command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
