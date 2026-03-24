import Foundation

enum SystemUtils {
    /// Get set of TCP ports currently in LISTEN state
    static func getListeningPorts() -> Set<UInt16> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk '{print $9}'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        var ports = Set<UInt16>()
        for line in stdout.components(separatedBy: .newlines) {
            if let colonIdx = line.lastIndex(of: ":") {
                let portStr = line[line.index(after: colonIdx)...]
                if let port = UInt16(portStr) {
                    ports.insert(port)
                }
            }
        }
        return ports
    }

    /// Check if a process with given PID is running
    static func isProcessRunning(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }

    /// Get running PID for a project path
    static func getRunningPid(projectPath: String) -> Int32? {
        // Check PID file first
        let pidFile = (projectPath as NSString).appendingPathComponent(".orch/orch3.pid")
        if let content = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, isProcessRunning(pid) {
            return pid
        }

        // Fallback: ps
        let projName = (projectPath as NSString).lastPathComponent
        let cmd = "ps axo pid,command | grep -E 'orch3-\(projName)|Electron.*\(projectPath)' | grep -v grep | grep -v Helper | head -1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty,
           let pidStr = stdout.split(separator: " ").first,
           let pid = Int32(pidStr), pid > 0 {
            return pid
        }
        return nil
    }

    /// Run a shell command in the background (fire and forget)
    static func shellBackground(_ cmd: String, currentDir: String? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        if let dir = currentDir {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Kill PIDs listening on a given port
    static func killPortListeners(port: UInt16) {
        let cmd = "lsof -iTCP:\(port) -sTCP:LISTEN -P -n -t 2>/dev/null"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        for line in stdout.components(separatedBy: .newlines) {
            if let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                kill(pid, SIGTERM)
            }
        }
    }
}
