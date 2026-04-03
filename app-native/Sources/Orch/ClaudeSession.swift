import Foundation

class ClaudeSession {
    private var fileHandle: FileHandle?
    private var childPid: pid_t = 0
    private(set) var running = false
    private var mode: SessionMode
    private let projectPath: String
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var lastActivity = Date()
    var masterFd: Int32 = -1

    var onData: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(projectPath: String, cols: Int, rows: Int, mode: SessionMode) {
        self.projectPath = projectPath
        self.cols = cols
        self.rows = rows
        self.mode = mode
    }

    func spawn() {
        let claudePath = resolveClaudePath()
        print("[orch] using claude at: \(claudePath)")

        var args = ["--dangerously-skip-permissions"]
        switch mode {
        case .new: break
        case .continue_: args.append("--continue")
        case .resume(let id): args += ["--resume", id]
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
            print("[orch] forkpty failed: \(errno)")
            return
        }

        if pid == 0 {
            // Child process
            chdir(projectPath)

            // Set up environment
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
                if let str = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.lastActivity = Date()
                        self?.onData?(str)
                    }
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

        print("[orch] session spawned, pid=\(pid)")
    }

    func write(_ data: String) {
        guard running, masterFd >= 0 else { return }
        data.withCString { ptr in
            let len = strlen(ptr)
            _ = Foundation.write(masterFd, ptr, len)
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
