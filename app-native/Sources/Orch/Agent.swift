import Foundation

/// Which coding-agent CLI drives a session. LM Studio runs through Codex's
/// native local-provider support, so it and Codex share the `codex` binary but
/// differ in launch flags.
enum Agent: String, Codable {
    case claude
    case codex
    case lmstudio

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .lmstudio: return "LM Studio"
        }
    }

    /// Short label for the status-bar model chip.
    var shortLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .lmstudio: return "LM"
        }
    }

    var binaryName: String {
        switch self {
        case .claude: return "claude"
        case .codex, .lmstudio: return "codex"
        }
    }

    /// Common install locations to fall back on when the login shell's PATH
    /// isn't available (the app inherits launchd's minimal PATH).
    var commonPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .claude:
            return ["\(home)/.local/bin/claude", "\(home)/.claude/bin/claude",
                    "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        case .codex, .lmstudio:
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
        }
    }
}

/// A model exposed by LM Studio (`lms ls --json`), used to fill the agent picker.
struct LMStudioModel: Equatable {
    let key: String          // modelKey — passed to `codex -m`
    let displayName: String

    static func list() -> [LMStudioModel] {
        guard let lms = AgentTools.resolve("lms",
                common: ["\(NSHomeDirectory())/.lmstudio/bin/lms", "/opt/homebrew/bin/lms"]),
              let out = AgentTools.runCapture(lms, ["ls", "--json"]),
              let data = out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard (m["type"] as? String) == "llm", let key = m["modelKey"] as? String else { return nil }
            return LMStudioModel(key: key, displayName: (m["displayName"] as? String) ?? key)
        }
    }
}

/// Shared helpers for locating and running the agent CLIs.
enum AgentTools {
    /// Absolute path to `name`, resolved against the interactive login shell's
    /// PATH (where these tools live) with a fallback to known install locations.
    static func resolve(_ name: String, common: [String] = []) -> String? {
        for cmd in ["zsh -ilc \"command -v \(name)\"", "bash -lc \"command -v \(name)\""] {
            if let p = runShell(cmd)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty, !p.contains("not found"),
               FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        for p in common where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    static func runShell(_ command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    static func runCapture(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }
}
