import Foundation
import CoreGraphics
import AppKit

enum SystemUtils {
    /// Get the screen-space bounds of the main window for a given PID, or nil if not found
    static func getWindowBounds(pid: Int32) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infoList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// Determine which NSScreen contains the center of a CG-coordinate rect
    static func screenForCGRect(_ rect: CGRect) -> NSScreen? {
        // CG coordinates: origin top-left. NSScreen: origin bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let centerX = rect.midX
        let centerY = primaryHeight - rect.midY  // flip to NS coordinates
        let nsPoint = NSPoint(x: centerX, y: centerY)
        return NSScreen.screens.first { $0.frame.contains(nsPoint) } ?? NSScreen.main
    }
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

    /// Check if a PID belongs to an orch process
    static func isOrchProcess(_ pid: Int32) -> Bool {
        let cmd = "ps -p \(pid) -o command= 2>/dev/null"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let stdout = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").lowercased()
        return stdout.contains("orch")
    }

    /// Get running PID for a project path
    static func getRunningPid(projectPath: String) -> Int32? {
        // Check PID file first
        let pidFile = (projectPath as NSString).appendingPathComponent(".orch/orch.pid")
        if let content = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, isProcessRunning(pid) {
            // Verify it's actually an orch process, not a recycled PID
            if isOrchProcess(pid) {
                return pid
            }
            // Stale PID file — clean it up
            try? FileManager.default.removeItem(atPath: pidFile)
        }

        // Fallback: ps
        let projName = (projectPath as NSString).lastPathComponent
        let cmd = "ps axo pid,command | grep -E 'orch-\(projName)' | grep -v grep | grep -v Helper | head -1"
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

    /// Resolve the absolute path to the `orch` CLI.
    ///
    /// The launcher executable lives at `<repo>/launcher-native/orch-launcher`, so
    /// `orch` is its sibling at `<repo>/bin/orch`. Resolving it explicitly avoids
    /// relying on $PATH, which is stripped to a minimal default when the launcher is
    /// run as a Dock `.app` rather than from a terminal.
    static func orchExecutable() -> String {
        if let execPath = Bundle.main.executablePath {
            let execDir = (execPath as NSString).deletingLastPathComponent
            let candidate = (execDir as NSString)
                .appendingPathComponent("../bin/orch")
            let resolved = (candidate as NSString).standardizingPath
            if FileManager.default.isExecutableFile(atPath: resolved) {
                return resolved
            }
        }
        return "orch"  // fall back to $PATH lookup
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
