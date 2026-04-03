import AppKit

// --- Parse CLI args ---
var projectPath = FileManager.default.currentDirectoryPath
var sessionMode: SessionMode = .new

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
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
