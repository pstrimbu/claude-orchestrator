import AppKit
import SwiftUI
import SwiftTerm

class AppDelegate: NSObject, NSApplicationDelegate, TerminalViewDelegate {
    let projectPath: String
    let sessionMode: SessionMode

    private var window: NSWindow!
    private var config: Config!
    private var session: ClaudeSession!
    private var clockify: ClockifyService!
    private var tracker: TrackerService!
    private var history: CommandHistoryService!
    private var overlay = OverlayManager()
    private var statusBarState = StatusBarState()
    private var statusBarModel = StatusBarModel()
    private var terminalView: TerminalView!

    private var statusTimer: Timer?
    private var gitPollTimer: Timer?
    private var lastPtyOutputTime: Date = .distantPast
    private var lastCommand = ""
    private var inputBuffer = ""

    // Keep signal sources alive
    private var sigUsr1Source: DispatchSourceSignal?
    private var sigUsr2Source: DispatchSourceSignal?

    // Scrollback
    private let scrollbackMax = 256 * 1024
    private var scrollbackBuf = ""

    init(projectPath: String, sessionMode: SessionMode) {
        self.projectPath = projectPath
        self.sessionMode = sessionMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let projectName = (projectPath as NSString).lastPathComponent
        let appName = "orch \u{2014} \(projectName)"
        NSApp.setActivationPolicy(.regular)

        // Initialize services
        config = Config(projectPath: projectPath)
        clockify = ClockifyService(config: config)
        tracker = createTracker(config: config)
        history = CommandHistoryService(orchDir: config.orchDir)

        // Restore last command from history
        if let last = history.getRecent(1).last {
            lastCommand = last.cmd
        }

        // Wire up Clockify summary provider
        clockify.setSummaryProvider { [weak self] in
            guard let self = self else { return "Active work" }
            let entries = self.history.getSinceLastFlush()
            if entries.isEmpty { return "Active work on \(self.config.projectId)" }
            let cmds = Array(Set(entries.map(\.cmd))).suffix(20)
            let cmdList = cmds.joined(separator: "\n")

            guard let apiKey = self.config.anthropicApiKey else {
                self.history.markFlushed()
                return cmds.suffix(5).joined(separator: "; ")
            }

            do {
                let url = URL(string: "https://api.anthropic.com/v1/messages")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                let body: [String: Any] = [
                    "model": "claude-haiku-4-5-20251001",
                    "max_tokens": 100,
                    "messages": [["role": "user", "content": "Summarize this developer's work session in 1-2 brief phrases for a time tracking entry (max 120 chars). Only output the summary, nothing else.\n\nCommands run:\n\(cmdList)"]],
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = (json["content"] as? [[String: Any]])?.first,
                   let text = (content["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    self.history.markFlushed()
                    return text.count > 120 ? String(text.prefix(117)) + "..." : text
                }
            } catch {}

            self.history.markFlushed()
            let summary = cmds.suffix(5).joined(separator: "; ")
            return summary.count > 120 ? String(summary.prefix(117)) + "..." : summary
        }

        // Create window
        createWindow(appName: appName)

        // Write PID file
        try? FileManager.default.createDirectory(atPath: config.orchDir, withIntermediateDirectories: true)
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: config.orchDir + "/orch.pid", atomically: true, encoding: .utf8)

        // Register with launcher
        registerWithLauncher()

        // Spawn Claude session using terminal dimensions
        let terminal = terminalView.getTerminal()
        spawnSession(cols: terminal.cols, rows: terminal.rows)

        // Start polling
        pollGitInfo()
        sendStatusUpdate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendStatusUpdate()
        }
        gitPollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.pollGitInfo()
        }

        // Handle SIGUSR1 — focus window
        signal(SIGUSR1, SIG_IGN)
        let src1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src1.setEventHandler { [weak self] in
            self?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        src1.resume()
        sigUsr1Source = src1

        // Handle SIGUSR2 — window commands from launcher
        signal(SIGUSR2, SIG_IGN)
        let src2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        src2.setEventHandler { [weak self] in self?.handleWindowCommand() }
        src2.resume()
        sigUsr2Source = src2

        // Replay saved scrollback
        replayScrollback()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window creation

    private func createWindow(appName: String) {
        // Create terminal view — display-only, we manage the PTY ourselves
        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 772))
        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = NSColor(red: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(red: 0xcc/255, green: 0xcc/255, blue: 0xcc/255, alpha: 1)
        if let font = NSFont(name: "Menlo", size: 13) {
            terminalView.font = font
        }

        // Status bar
        statusBarModel.onSectionClick = { [weak self] section in
            self?.openSection(section)
        }
        let statusBar = NSHostingView(rootView: StatusBarView(model: statusBarModel))
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        // Overlay (SwiftUI layer on top of terminal)
        let overlayHost = NSHostingView(rootView: OverlayView(overlay: overlay))
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        // Make overlay transparent to mouse when not visible
        overlayHost.wantsLayer = true

        // Container
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 1).cgColor

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)
        container.addSubview(terminalView)
        container.addSubview(overlayHost)

        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: container.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),

            terminalView.topAnchor.constraint(equalTo: statusBar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            overlayHost.topAnchor.constraint(equalTo: container.topAnchor),
            overlayHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlayHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.contentView = container
        window.center()
        window.backgroundColor = NSColor(red: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true

        // Set up application menu with project name
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (needed for copy/paste in terminal)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu

        // Check for position hint from Cmd+N
        let posPath = config.orchDir + "/new-window-pos.json"
        if let posData = try? Data(contentsOf: URL(fileURLWithPath: posPath)),
           let pos = try? JSONSerialization.jsonObject(with: posData) as? [String: Any] {
            try? FileManager.default.removeItem(atPath: posPath)
            if let x = pos["x"] as? Int, let y = pos["y"] as? Int {
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            if let w = pos["w"] as? Int, let h = pos["h"] as? Int {
                window.setContentSize(NSSize(width: w, height: h))
            }
        }
    }

    // MARK: - TerminalViewDelegate

    /// Called when the terminal has data to send (keyboard input from user)
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)

        // Check for overlay input first
        if overlay.visible {
            if let str = String(bytes: bytes, encoding: .utf8) {
                let key = translateTerminalInput(str)
                overlay.handleKey(key)
            }
            return
        }

        // Check for hotkeys
        if let str = String(bytes: bytes, encoding: .utf8), handleHotkey(str) {
            return
        }

        // Track user input to capture last command
        if let str = String(bytes: bytes, encoding: .utf8) {
            if str == "\r" || str == "\n" {
                let cmd = inputBuffer.trimmingCharacters(in: .whitespaces)
                if !cmd.isEmpty {
                    lastCommand = cmd
                    history.append(cmd)
                    sendStatusUpdate()
                }
                inputBuffer = ""
            } else if str == "\u{7f}" {
                inputBuffer = String(inputBuffer.dropLast())
            } else if str.count == 1, let scalar = str.unicodeScalars.first, scalar.value >= 32 {
                inputBuffer += str
            }
        }

        // Forward to Claude PTY
        if session?.running == true {
            let dataToWrite = Data(bytes)
            dataToWrite.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    _ = write(session.masterFd, base, bytes.count)
                }
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // We manage our own title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: - Input translation

    private func translateTerminalInput(_ data: String) -> String {
        if data == "\u{1b}" || data == "\u{1b}\u{1b}" { return "escape" }
        if data == "\r" { return "return" }
        if data == "\u{7f}" { return "backspace" }
        if data == "\u{1b}[A" { return "up" }
        if data == "\u{1b}[B" { return "down" }
        if data.count == 1, let s = data.unicodeScalars.first, s.value >= 32 { return data }
        return data
    }

    private func handleHotkey(_ data: String) -> Bool {
        // F1: \x1bOP — open project panel
        if data == "\u{1b}OP" {
            openSection("project")
            return true
        }
        // F5: \x1b[15~
        if data == "\u{1b}[15~" {
            handleF5()
            return true
        }
        // Ctrl+R: \x12
        if data == "\u{12}" {
            handleCtrlR()
            return true
        }
        // Cmd+N is handled via menu/key equivalent
        return false
    }

    private func handleF5() {
        saveScrollback()
        if clockify.recording { Task { try? await clockify.flush() } }
        session?.kill()
        // Relaunch via orch
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "orch \"\(projectPath)\" --continue"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        NSApp.terminate(nil)
    }

    private func handleCtrlR() {
        // Restart session with --continue
        saveScrollback()
        session?.kill()
        let terminal = terminalView.getTerminal()
        session = ClaudeSession(projectPath: projectPath, cols: terminal.cols, rows: terminal.rows, mode: .continue_)
        session.onData = { [weak self] data in
            self?.handleSessionData(data)
        }
        session.onExit = { [weak self] code in
            self?.handleSessionExit(code)
        }
        session.spawn()
    }

    // MARK: - Session

    private func spawnSession(cols: Int, rows: Int) {
        session = ClaudeSession(
            projectPath: projectPath,
            cols: max(cols, 10),
            rows: max(rows, 5),
            mode: sessionMode
        )
        session.onData = { [weak self] data in
            self?.handleSessionData(data)
        }
        session.onExit = { [weak self] code in
            self?.handleSessionExit(code)
        }
        session.spawn()
    }

    private func handleSessionData(_ data: String) {
        var processed = data
        processed = processed
            .replacingOccurrences(of: "\u{1b}[3J", with: "")
            .replacingOccurrences(of: "\u{1b}[?1049h", with: "")
            .replacingOccurrences(of: "\u{1b}[?1049l", with: "")
            .replacingOccurrences(of: "\u{1b}[?47h", with: "")
            .replacingOccurrences(of: "\u{1b}[?47l", with: "")

        appendScrollback(processed)
        lastPtyOutputTime = Date()
        terminalView.feed(text: processed)
        clockify.onActivity()
    }

    private func handleSessionExit(_ code: Int32) {
        terminalView.feed(text: "\r\n\u{1b}[90m[Session exited with code \(code)]\u{1b}[0m\r\n")
    }

    // MARK: - Scrollback

    private func appendScrollback(_ data: String) {
        scrollbackBuf += data
        if scrollbackBuf.count > scrollbackMax * 3 / 2 {
            scrollbackBuf = String(scrollbackBuf.suffix(scrollbackMax))
        }
    }

    private func saveScrollback() {
        try? FileManager.default.createDirectory(atPath: config.orchDir, withIntermediateDirectories: true)
        try? scrollbackBuf.write(toFile: config.orchDir + "/scrollback.buf", atomically: true, encoding: .utf8)
    }

    private func replayScrollback() {
        let bufPath = config.orchDir + "/scrollback.buf"
        guard FileManager.default.fileExists(atPath: bufPath),
              let data = try? String(contentsOfFile: bufPath, encoding: .utf8),
              !data.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: bufPath)
        scrollbackBuf = data
        let clean = sanitizeScrollback(data)
        if !clean.isEmpty {
            terminalView.feed(text: clean)
        }
    }

    private func sanitizeScrollback(_ data: String) -> String {
        var result = data
        let patterns = [
            "\u{1b}c",
            "\u{1b}[3J",
            "\u{1b}[?1004h", "\u{1b}[?1004l",
            "\u{1b}[?2004h", "\u{1b}[?2004l",
            "\u{1b}[?1049h", "\u{1b}[?1049l",
            "\u{1b}[?47h", "\u{1b}[?47l",
            "\u{1b}[?1h", "\u{1b}[?1l",
            "\u{1b}[?u",
        ]
        for p in patterns { result = result.replacingOccurrences(of: p, with: "") }
        result = result.replacingOccurrences(of: "\u{1b}\\[[>?=]?c", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1b}\\[6n", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1b}\\[\\?100[0-6][hl]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1b}\\[>[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1b}\\[>[0-9]*u", with: "", options: .regularExpression)
        return result
    }

    // MARK: - Git polling

    private func pollGitInfo() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let branch = self.shellOutput("git rev-parse --abbrev-ref HEAD", cwd: self.config.projectPath)
            let status = self.shellOutput("git status --short", cwd: self.config.projectPath)
            DispatchQueue.main.async {
                self.statusBarState.gitBranch = branch ?? ""
                self.statusBarState.gitDirty = !(status ?? "").isEmpty
            }
        }
    }

    // MARK: - Status update

    private func sendStatusUpdate() {
        window?.title = "orch \u{2014} \(config.projectName)"
        statusBarModel.data = StatusBarData(
            claudeActive: Date().timeIntervalSince(lastPtyOutputTime) < 2,
            projectName: config.projectName,
            timeElapsed: clockify.formatElapsed(),
            timeRecording: clockify.recording,
            trackerEnabled: tracker.enabled,
            trackerTeamKey: tracker.teamKey,
            currentIssueKey: statusBarState.currentIssue?.key,
            currentIssueTitle: statusBarState.currentIssue?.title,
            gitBranch: statusBarState.gitBranch,
            gitDirty: statusBarState.gitDirty,
            lastCommand: lastCommand
        )
    }

    // MARK: - Sections

    private func openSection(_ section: String) {
        switch section {
        case "project":
            showProjectOverlay(overlay: overlay, config: config, statusBar: statusBarState,
                               onTrackerRefresh: { [weak self] in self?.refreshTracker() },
                               onUpdate: { [weak self] in self?.sendStatusUpdate() })
        case "time":
            showTimeOverlay(overlay: overlay, clockify: clockify,
                            onUpdate: { [weak self] in self?.sendStatusUpdate() })
        case "issues":
            showIssuesOverlay(overlay: overlay, tracker: tracker, session: session, statusBar: statusBarState, config: config,
                              onTrackerRefresh: { [weak self] in self?.refreshTracker() },
                              onUpdate: { [weak self] in self?.sendStatusUpdate() })
        case "git":
            showGitOverlay(overlay: overlay, config: config, session: session,
                           onUpdate: { [weak self] in self?.sendStatusUpdate() })
        case "history":
            showHistoryOverlay(overlay: overlay, history: history, session: session,
                               onUpdate: { [weak self] in self?.sendStatusUpdate() })
        case "prompt":
            showPromptBuilderOverlay(overlay: overlay, config: config, session: session)
        default: break
        }
    }

    private func refreshTracker() {
        config.reload()
        tracker = createTracker(config: config)
    }

    // MARK: - Window commands (SIGUSR2)

    private func handleWindowCommand() {
        let cmdPath = config.orchDir + "/window-cmd.json"
        guard FileManager.default.fileExists(atPath: cmdPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: cmdPath)),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? FileManager.default.removeItem(atPath: cmdPath)

        if let x = cmd["x"] as? Int, let y = cmd["y"] as? Int {
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        if cmd["focus"] as? Bool == true {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Launcher registration

    private func registerWithLauncher() {
        let configDir = NSHomeDirectory() + "/.config/orch"
        let configFile = configDir + "/launcher-projects.json"
        let name = (projectPath as NSString).lastPathComponent

        var projects: [[String: String]] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = json["projects"] as? [[String: String]] {
            projects = existing
        }
        if projects.contains(where: { $0["path"] == projectPath }) { return }

        projects.append(["path": projectPath, "name": name])
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let json: [String: Any] = ["projects": projects]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: configFile))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        proc.arguments = ["-p", "com.orch.reload-projects"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    // MARK: - Cleanup

    func applicationWillTerminate(_ notification: Notification) {
        if clockify?.recording == true {
            Task { try? await clockify.flush() }
        }
        statusTimer?.invalidate()
        gitPollTimer?.invalidate()
        clockify?.destroy()
        session?.kill()
        try? FileManager.default.removeItem(atPath: config.orchDir + "/orch.pid")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Helpers

    private func shellOutput(_ command: String, cwd: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }
}
