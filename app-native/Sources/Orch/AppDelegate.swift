import AppKit
import SwiftUI
import SwiftTerm

class OrchWindow: NSWindow {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let handler = onKeyEquivalent, handler(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, TerminalViewDelegate {
    let projectPath: String
    let sessionMode: SessionMode

    private var window: OrchWindow!
    private var config: Config!
    private var session: ClaudeSession!
    private var clockify: ClockifyService!
    private var tracker: TrackerService!
    private var history: CommandHistoryService!
    private var sessionStore: SessionStore!
    private var overlay = OverlayManager()
    private var statusBarState = StatusBarState()
    private var statusBarModel = StatusBarModel()
    private var terminalView: TerminalView!

    private var sessionSize = SessionSizeService()
    private var statusTimer: Timer?
    private var gitPollTimer: Timer?
    private var sizePollTimer: Timer?
    private var prPollTimer: Timer?
    private var usagePollTimer: Timer?
    private var lastPtyOutputTime: Date = .distantPast
    private var lastCommand = ""
    private var inputBuffer = ""
    private var remoteControlEnabled = false

    // Attention state: Claude emitted output responding to the user, then went
    // quiet — it's the user's turn. Cleared when they type or output resumes.
    private var sawOutputSinceInput = false
    private var lastUserInputTime: Date = .distantPast
    // Burn-rate sampling: (cumulative tokens, timestamp) of the previous sample.
    private var lastTokenSample: (tokens: Int, time: Date)?

    // Keep signal sources alive
    private var sigUsr1Source: DispatchSourceSignal?
    private var sigUsr2Source: DispatchSourceSignal?

    // App Nap opt-out — keeps SwiftTerm redrawing in real time when window
    // is not frontmost. Without this, macOS throttles the view's draw loop
    // and PTY output / typed input only repaint after a click.
    private var activityToken: NSObjectProtocol?

    // Scrollback
    private let scrollbackMax = 256 * 1024
    private var scrollbackBuf = ""

    // Scroll-pinning: when the user scrolls up, hold the viewport at that
    // absolute row through subsequent feeds instead of snapping to bottom.
    private var userScrolledUp = false
    private var feeding = false

    init(projectPath: String, sessionMode: SessionMode) {
        self.projectPath = projectPath
        self.sessionMode = sessionMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let projectName = (projectPath as NSString).lastPathComponent
        let appName = "orch \u{2014} \(projectName)"
        NSApp.setActivationPolicy(.regular)

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Interactive terminal session — realtime PTY updates"
        )

        // Initialize services
        config = Config(projectPath: projectPath)
        Log.setup(orchDir: config.orchDir)
        Log.log("projectPath: \(projectPath)")
        clockify = ClockifyService(config: config)
        tracker = createTracker(config: config)
        history = CommandHistoryService(orchDir: config.orchDir)
        sessionStore = SessionStore(projectPath: projectPath)

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

            // Use AWS Bedrock (Claude Haiku) for AI summary via boto3
            do {
                let escapedCmds = cmdList.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                let pyScript = """
                import boto3, json, sys
                c = boto3.client('bedrock-runtime', region_name='us-east-1')
                r = c.invoke_model(
                    modelId='us.anthropic.claude-haiku-4-5-20251001-v1:0',
                    contentType='application/json',
                    accept='application/json',
                    body=json.dumps({
                        'anthropic_version': 'bedrock-2023-05-31',
                        'max_tokens': 100,
                        'messages': [{'role': 'user', 'content': 'Summarize this developer\\'s work session in 1-2 brief phrases for a time tracking entry (max 120 chars). Only output the summary, nothing else.\\n\\nCommands run:\\n\(escapedCmds)'}]
                    })
                )
                body = json.loads(r['body'].read())
                print(body['content'][0]['text'].strip())
                """
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                proc.arguments = ["-c", pyScript]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    let text = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.history.markFlushed()
                        return text.count > 120 ? String(text.prefix(117)) + "..." : text
                    }
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
        Log.log("terminal size: \(terminal.cols)x\(terminal.rows)")
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
        pollSessionSize()
        sizePollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.pollSessionSize()
        }
        pollPR()
        prPollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.pollPR()
        }
        pollUsage()
        usagePollTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.pollUsage()
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
        terminalView.allowMouseReporting = false

        // Status bar
        statusBarModel.onSectionClick = { [weak self] section in
            self?.openSection(section)
        }
        let statusBar = NSHostingView(rootView: StatusBarView(model: statusBarModel))
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        // Window — create first so we can constrain to its contentView
        window = OrchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.onKeyEquivalent = { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return false }
            switch event.charactersIgnoringModifiers {
            case "n":
                self?.handleCmdN()
                return true
            default:
                return false
            }
        }
        window.title = appName
        window.center()
        window.backgroundColor = NSColor(red: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .visible

        // Use frame-based layout with autoresizing masks
        let container = window.contentView!
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 1).cgColor
        let cw = container.bounds.width
        let ch = container.bounds.height
        let statusH: CGFloat = 28

        statusBar.translatesAutoresizingMaskIntoConstraints = true
        statusBar.frame = NSRect(x: 0, y: ch - statusH, width: cw, height: statusH)
        statusBar.autoresizingMask = [.width, .minYMargin]

        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.frame = NSRect(x: 0, y: 0, width: cw, height: ch - statusH)
        terminalView.autoresizingMask = [.width, .height]

        container.addSubview(terminalView)
        container.addSubview(statusBar)
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

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(handleCmdN), keyEquivalent: "n")
        windowMenu.addItem(newWindowItem)
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

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
        // Check for hotkeys
        if let str = String(bytes: bytes, encoding: .utf8), handleHotkey(str) {
            return
        }

        // Any keystroke means the user is engaged — clear the "your turn" state.
        sawOutputSinceInput = false
        lastUserInputTime = Date()

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

        // Forward to Claude PTY (off main thread — see ClaudeSession.writeQueue)
        session?.write(bytes)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // We manage our own title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {
        // Ignore callbacks fired by our own feed (auto-snap to bottom).
        // Only genuine user scrolls update the pin state.
        if feeding { return }
        userScrolledUp = position < 1.0 - 1e-6
    }

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

    private func handleHotkey(_ data: String) -> Bool {
        // F1: \x1bOP — open project panel
        if data == "\u{1b}OP" {
            openSection("project")
            return true
        }
        // F2: \x1bOQ — open sessions panel
        if data == "\u{1b}OQ" {
            openSection("sessions")
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

    @objc private func handleCmdN() {
        // Spawn a new orch window for the same project, offset from current position
        let frame = window.frame
        let offsetX = Int(frame.origin.x) + 30
        let offsetY = Int(frame.origin.y) - 30
        let w = Int(frame.width)
        let h = Int(frame.height)
        let cmdPath = config.orchDir + "/new-window-pos.json"
        let pos: [String: Int] = ["x": offsetX, "y": offsetY, "w": w, "h": h]
        if let data = try? JSONSerialization.data(withJSONObject: pos) {
            try? data.write(to: URL(fileURLWithPath: cmdPath))
        }
        let orch = resolveOrchPath()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "\"\(orch)\" '\(projectPath)'"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    private func handleF5() {
        saveScrollback()
        if clockify.recording { Task { try? await clockify.flush() } }

        // Relaunch needs the orch CLI. The .app bundle inherits launchd's minimal
        // PATH, so resolve orch's absolute path first. If it can't be found, fall
        // back to an in-place session restart rather than terminating into a
        // closed window (the reported "F5 closes but doesn't reopen" bug).
        let orch = resolveOrchPath()
        guard FileManager.default.isExecutableFile(atPath: orch) else {
            Log.log("F5: orch not resolvable (\(orch)); falling back to in-place restart")
            handleCtrlR()
            return
        }

        session?.kill()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "\"\(orch)\" \"\(projectPath)\" --continue"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            Log.log("F5 relaunch spawn failed: \(error); falling back to in-place restart")
            handleCtrlR()  // session already killed; Ctrl+R respawns --continue
            return
        }
        NSApp.terminate(nil)
    }

    private func handleCtrlR() {
        // Restart session with --continue
        saveScrollback()
        session?.kill()
        let terminal = terminalView.getTerminal()
        session = ClaudeSession(projectPath: projectPath, cols: terminal.cols, rows: terminal.rows, mode: .continue_,
                                remoteControl: remoteControlEnabled, remoteName: config.projectName)
        session.onData = { [weak self] data in
            self?.handleSessionData(data)
        }
        session.onExit = { [weak self] code in
            self?.handleSessionExit(code)
        }
        session.spawn()
    }

    private func toggleRemoteControl() {
        remoteControlEnabled.toggle()
        sendStatusUpdate()

        // Remote Control is a launch mode, not an in-session command — so restart
        // the Claude session with (or without) `--remote-control`, resuming the same
        // conversation via --continue. When enabling, Claude prints a QR code +
        // session URL to the terminal; scan it with the Claude mobile app to drive
        // this session from your phone. The session stays local; the phone is a UI.
        let banner = remoteControlEnabled
            ? "\r\n\u{1b}[1;32m[Remote Control ON \u{2014} scan the QR / open the session URL below in the Claude app. Restarting session\u{2026}]\u{1b}[0m\r\n"
            : "\r\n\u{1b}[1;90m[Remote Control OFF \u{2014} restarting session\u{2026}]\u{1b}[0m\r\n"
        terminalView.feed(byteArray: [UInt8](banner.utf8)[...])
        forceRepaint()

        saveScrollback()
        session?.kill()
        let terminal = terminalView.getTerminal()
        session = ClaudeSession(
            projectPath: projectPath,
            cols: terminal.cols,
            rows: terminal.rows,
            mode: .continue_,
            remoteControl: remoteControlEnabled,
            remoteName: config.projectName
        )
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
            mode: sessionMode,
            remoteControl: remoteControlEnabled,
            remoteName: config.projectName
        )
        session.onData = { [weak self] data in
            self?.handleSessionData(data)
        }
        session.onExit = { [weak self] code in
            self?.handleSessionExit(code)
        }
        session.spawn()
    }

    private func handleSessionData(_ data: Data) {
        // Strip clear-scrollback sequence (ESC[3J) at byte level
        var bytes = [UInt8](data)
        let clearSeq: [UInt8] = [0x1b, 0x5b, 0x33, 0x4a]  // \x1b[3J
        while let range = bytes.firstRange(of: clearSeq) {
            bytes.removeSubrange(range)
        }

        // Feed raw bytes to SwiftTerm — avoids UTF-8 boundary issues
        if !bytes.isEmpty {
            appendScrollback(bytes)
            lastPtyOutputTime = Date()
            sawOutputSinceInput = true

            // Save absolute viewport row before feed so we can restore it if
            // the user is reading scrollback. SwiftTerm otherwise snaps yDisp
            // back to yBase on every linefeed.
            let savedYDisp = terminalView.getTerminal().buffer.yDisp
            let wasScrolledUp = userScrolledUp

            feeding = true
            terminalView.feed(byteArray: bytes[...])
            feeding = false

            if wasScrolledUp {
                terminalView.scrollTo(row: savedYDisp)
            }

            // Force synchronous repaint on this runloop tick. SwiftTerm's
            // feed() calls setNeedsDisplay internally, but AppKit can defer
            // the actual paint to the next event-driven frame — which makes
            // typed input invisible until a mouse click flushes the queue.
            forceRepaint()

            clockify.onActivity()
        }
    }

    /// Force a synchronous full repaint of the terminal view.
    ///
    /// SwiftTerm's `feed()` does not paint directly — it calls `queuePendingDisplay()`,
    /// which throttles by scheduling its internal `updateDisplay()` (the call that
    /// actually invalidates the view) on a main-queue timer, guarded by a
    /// `pendingDisplay` flag. A bare `displayIfNeeded()` right after `feed()` runs
    /// *before* that timer fires, so the view isn't marked dirty yet and the flush is
    /// a no-op — repaints depend entirely on the throttle timer. If that timer is
    /// starved (main runloop in event-tracking mode while an NSMenu overlay is open)
    /// or its flag gets wedged, typed echo and PTY output stop appearing until an
    /// unrelated full redraw (line wrap, scroll, resize) fires — the "text doesn't
    /// show until I pass end of line" symptom after a long session.
    ///
    /// SwiftTerm's `draw()` renders straight from the current terminal buffer for
    /// whatever rect is invalid, so marking the whole view dirty ourselves and
    /// flushing on the same runloop tick guarantees the latest content is shown,
    /// independent of the throttle. The throttled `updateDisplay()` still runs and
    /// keeps the caret/accessibility in sync.
    private func forceRepaint() {
        terminalView.needsDisplay = true
        terminalView.displayIfNeeded()
    }

    private func handleSessionExit(_ code: Int32) {
        Log.log("session exited with code \(code)")
        let msg = "\r\n\u{1b}[90m[Session exited with code \(code)]\u{1b}[0m\r\n"
        terminalView.feed(byteArray: [UInt8](msg.utf8)[...])
        forceRepaint()
    }

    // MARK: - Scrollback

    private func appendScrollback(_ bytes: [UInt8]) {
        if let str = String(bytes: bytes, encoding: .utf8) {
            scrollbackBuf += str
        } else {
            // Lossy conversion for scrollback — replace invalid bytes
            scrollbackBuf += String(decoding: bytes, as: UTF8.self)
        }
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
            terminalView.feed(byteArray: [UInt8](clean.utf8)[...])
            forceRepaint()
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
            let cwd = self.config.projectPath
            let branch = self.shellOutput("git rev-parse --abbrev-ref HEAD", cwd: cwd)
            let status = self.shellOutput("git status --short", cwd: cwd)
            // Ahead/behind vs upstream (blank when no upstream is configured).
            var ahead = 0, behind = 0
            if let counts = self.shellOutput("git rev-list --count --left-right @{u}...HEAD 2>/dev/null", cwd: cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !counts.isEmpty {
                let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if parts.count == 2 { behind = Int(parts[0]) ?? 0; ahead = Int(parts[1]) ?? 0 }
            }
            // Working-tree churn (staged + unstaged) vs HEAD.
            var added = 0, removed = 0
            if let stat = self.shellOutput("git diff HEAD --shortstat 2>/dev/null", cwd: cwd) {
                added = self.firstInt(in: stat, before: "insertion")
                removed = self.firstInt(in: stat, before: "deletion")
            }
            DispatchQueue.main.async {
                self.statusBarState.gitBranch = branch ?? ""
                self.statusBarState.gitDirty = !(status ?? "").isEmpty
                self.statusBarState.gitAhead = ahead
                self.statusBarState.gitBehind = behind
                self.statusBarState.diffAdded = added
                self.statusBarState.diffRemoved = removed
            }
        }
    }

    /// Parse the integer immediately preceding a word in a `git --shortstat`
    /// line, e.g. "3 files changed, 42 insertions(+), 5 deletions(-)".
    private func firstInt(in text: String, before word: String) -> Int {
        guard let range = text.range(of: word) else { return 0 }
        let head = text[..<range.lowerBound]
        let digits = head.reversed().drop(while: { $0 == " " }).prefix(while: { $0.isNumber })
        return Int(String(digits.reversed())) ?? 0
    }

    /// Poll the current branch's PR (open state + check rollup) via `gh`, on a
    /// slower cadence than git since it hits the network.
    private func pollPR() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let out = self.shellOutput(
                "gh pr view --json number,state,statusCheckRollup 2>/dev/null", cwd: self.config.projectPath)
            var number = 0
            var checks = ""
            if let out = out, let d = out.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               (o["state"] as? String) == "OPEN", let n = o["number"] as? Int {
                number = n
                if let rollup = o["statusCheckRollup"] as? [[String: Any]], !rollup.isEmpty {
                    var anyFail = false, anyPending = false
                    for c in rollup {
                        let concl = (c["conclusion"] as? String ?? "").uppercased()
                        let stat = (c["status"] as? String ?? "").uppercased()
                        if stat != "COMPLETED" && !stat.isEmpty { anyPending = true }
                        if concl == "FAILURE" || concl == "TIMED_OUT" || concl == "CANCELLED" { anyFail = true }
                    }
                    checks = anyFail ? "failing" : (anyPending ? "pending" : "passing")
                }
            }
            DispatchQueue.main.async {
                self.statusBarState.prNumber = number
                self.statusBarState.prChecks = checks
                self.sendStatusUpdate()
            }
        }
    }

    // Read the current session's context size from its transcript (off-main),
    // then push into the status bar. Cheap: re-parses only when the transcript
    // changes and reads just the tail.
    private func pollSessionSize() {
        let sid = sessionStore.currentSessionId(childPid: session?.childPid ?? 0)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let m = self.sessionSize.readMetrics(sessionId: sid) else { return }
            DispatchQueue.main.async {
                self.statusBarState.contextTokens = m.tokens
                self.statusBarState.contextLimit = m.limit
                self.statusBarState.contextModel = m.model
                self.statusBarState.costUSD = m.costUSD
                self.statusBarState.bgAgents = m.bgAgents
                // Burn rate: cumulative-token delta since the last sample, per
                // minute. Zeroes between turns (the chip then hides).
                let now = Date()
                if let prev = self.lastTokenSample {
                    let dt = now.timeIntervalSince(prev.time)
                    let dTok = max(0, m.cumulativeTokens - prev.tokens)
                    if dt >= 1 { self.statusBarState.burnRate = Int(Double(dTok) / dt * 60.0) }
                }
                self.lastTokenSample = (m.cumulativeTokens, now)
                self.sendStatusUpdate()
            }
        }
    }

    /// Aggregate the last 24h of token usage across this project's transcripts
    /// for the hover graph. Slower cadence — it scans sibling session files.
    private func pollUsage() {
        let sid = sessionStore.currentSessionId(childPid: session?.childPid ?? 0)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let buckets = self.sessionSize.hourlyUsage(sessionId: sid)
            DispatchQueue.main.async {
                self.statusBarState.usage24h = buckets
                self.sendStatusUpdate()
            }
        }
    }

    // MARK: - Status update

    private func sendStatusUpdate() {
        window?.title = "orch \u{2014} \(config.projectName)"
        let idle = Date().timeIntervalSince(lastPtyOutputTime)
        let active = idle < 2
        // "Your turn": Claude produced output responding to you and has been
        // quiet for a few seconds. Cleared once you type or output resumes.
        let attention = sawOutputSinceInput && !active && idle >= 3
        statusBarModel.data = StatusBarData(
            claudeActive: active,
            projectName: config.projectName,
            timeElapsed: clockify.formatElapsed(),
            timeRecording: clockify.recording,
            trackerEnabled: tracker.enabled,
            trackerTeamKey: tracker.teamKey,
            currentIssueKey: statusBarState.currentIssue?.key,
            currentIssueTitle: statusBarState.currentIssue?.title,
            gitBranch: statusBarState.gitBranch,
            gitDirty: statusBarState.gitDirty,
            sessionLabel: sessionLabel(),
            lastCommand: lastCommand,
            remoteActive: remoteControlEnabled,
            contextTokens: statusBarState.contextTokens,
            contextLimit: statusBarState.contextLimit,
            model: statusBarState.contextModel ?? "",
            costUSD: statusBarState.costUSD,
            burnRate: statusBarState.burnRate,
            bgAgents: statusBarState.bgAgents,
            gitAhead: statusBarState.gitAhead,
            gitBehind: statusBarState.gitBehind,
            diffAdded: statusBarState.diffAdded,
            diffRemoved: statusBarState.diffRemoved,
            prNumber: statusBarState.prNumber,
            prChecks: statusBarState.prChecks,
            attention: attention,
            usage24h: statusBarState.usage24h,
            projectPath: projectPath,
            recentCommands: history.getRecent(10).map { $0.cmd }
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
        case "sessions":
            showSessionsOverlay(
                overlay: overlay,
                sessionStore: sessionStore,
                session: session,
                currentSessionId: sessionStore.currentSessionId(childPid: session.childPid),
                onSessionSwitch: { [weak self] mode in self?.switchSession(mode) },
                onUpdate: { [weak self] in self?.sendStatusUpdate() }
            )
        case "size":
            showSessionSizeOverlay(
                overlay: overlay,
                session: session,
                state: statusBarState,
                onRestart: { [weak self] in self?.handleCtrlR() },
                onUpdate: { [weak self] in self?.sendStatusUpdate() })
        case "model":
            // Open Claude Code's model picker in the session.
            session?.write([UInt8]("/model\r".utf8))
        case "push":
            let cwd = config.projectPath
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.shellOutput("git push 2>&1", cwd: cwd)
                DispatchQueue.main.async { self?.pollGitInfo() }
            }
        case "pr":
            let cwd = config.projectPath
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.shellOutput("gh pr view --web 2>/dev/null", cwd: cwd)
            }
        case "newsession":
            handleCmdN()
        case "remote":
            toggleRemoteControl()
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

    private func sessionLabel() -> String {
        guard let id = sessionStore.currentSessionId(childPid: session.childPid) else { return "" }
        return String(id.prefix(8))
    }

    private func switchSession(_ mode: SessionMode) {
        saveScrollback()
        session?.kill()
        // Clear terminal and scrollback
        terminalView.feed(byteArray: [UInt8]("\u{1b}c".utf8)[...])
        forceRepaint()
        scrollbackBuf = ""
        let terminal = terminalView.getTerminal()
        session = ClaudeSession(
            projectPath: projectPath,
            cols: terminal.cols,
            rows: terminal.rows,
            mode: mode,
            remoteControl: remoteControlEnabled,
            remoteName: config.projectName
        )
        session.onData = { [weak self] data in
            self?.handleSessionData(data)
        }
        session.onExit = { [weak self] code in
            self?.handleSessionExit(code)
        }
        session.spawn()
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
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        if clockify?.recording == true {
            Task { try? await clockify.flush() }
        }
        statusTimer?.invalidate()
        gitPollTimer?.invalidate()
        sizePollTimer?.invalidate()
        prPollTimer?.invalidate()
        usagePollTimer?.invalidate()
        sizePollTimer?.invalidate()
        clockify?.destroy()
        session?.kill()
        try? FileManager.default.removeItem(atPath: config.orchDir + "/orch.pid")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Helpers

    /// Absolute path to the `orch` CLI.
    ///
    /// The app runs as a Dock `.app` bundle launched via `open`, so it inherits
    /// launchd's minimal PATH — a bare `orch` won't resolve and relaunch (F5) /
    /// new-window spawns fail silently. Resolve it through an *interactive* login
    /// shell: the PATH entry for orch's bin dir lives in ~/.zshrc, which is only
    /// sourced by interactive shells (a plain `-lc` login shell skips it). Falls
    /// back to the bare name so behavior is unchanged when PATH already has it.
    private func resolveOrchPath() -> String {
        for shell in ["/bin/zsh", "/bin/bash"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: shell)
            proc.arguments = ["-ilc", "command -v orch"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { continue }
            proc.waitUntilExit()
            let out = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty, !out.contains("not found"),
               FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        }
        return "orch"
    }

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
