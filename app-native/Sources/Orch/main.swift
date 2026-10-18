import AppKit

// --- Parse CLI args ---
var projectPath = FileManager.default.currentDirectoryPath
var sessionMode: SessionMode = .new
var launchInBackground = false
var launchMinimized = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--background":
        // Opened by a script (orch-worker), not by the user: don't take focus.
        launchInBackground = true
    case "--minimized":
        // A Loops worker: open straight into the Dock, never in front of the owner.
        launchInBackground = true
        launchMinimized = true
    case "-c", "--continue":
        sessionMode = .continue_
    case "-r", "--resume":
        i += 1
        guard i < args.count else {
            fputs("--resume requires a session ID\n", stderr)
            exit(1)
        }
        sessionMode = .resume(id: args[i])
    default:
        if !arg.hasPrefix("-") {
            projectPath = arg
        }
    }
    i += 1
}

// Resolve to absolute path
if !projectPath.hasPrefix("/") {
    projectPath = FileManager.default.currentDirectoryPath + "/" + projectPath
}
projectPath = (projectPath as NSString).standardizingPath

print("[orch] projectPath: \(projectPath)")

// Ensure we have a full user PATH — `open` launches with minimal launchd env
if let currentPath = ProcessInfo.processInfo.environment["PATH"],
   !currentPath.contains("/opt/homebrew") || !currentPath.contains(".local/bin") {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = ["-lc", "echo $PATH"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    if let _ = try? proc.run() {
        proc.waitUntilExit()
        if let resolved = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !resolved.isEmpty {
            setenv("PATH", resolved, 1)
        }
    }
}

// Drop session variables inherited from whatever launched us. When a Claude
// Code or Codex session runs `orch` / `orch-worker` (a lead starting workers),
// its CLAUDE_CODE_SESSION_ID, CLAUDE_CODE_CHILD_SESSION, messaging socket,
// CLAUDE_EFFORT… would otherwise reach our agent, which then runs as that
// session's *child*: no transcript of its own (so no resume) and the parent's
// effort level. Every orch session must start as its own top-level session.
for key in ProcessInfo.processInfo.environment.keys
where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_")
    || ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CONFIG_DIR"].contains(key) {
    unsetenv(key)
}

// Load .env files
EnvLoader.load(path: projectPath + "/.env")
let repoDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/../.."
EnvLoader.load(path: (repoDir as NSString).standardizingPath + "/.env")

// Set process name for Activity Monitor / dock
let projectName = (projectPath as NSString).lastPathComponent
ProcessInfo.processInfo.processName = "orch-\(projectName)"

// --- Launch app ---
let app = NSApplication.shared
let delegate = AppDelegate(projectPath: projectPath, sessionMode: sessionMode)
app.delegate = delegate
app.run()
