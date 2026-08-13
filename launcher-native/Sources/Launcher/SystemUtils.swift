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

    /// A one-shot snapshot of running processes (pid -> full command line).
    ///
    /// Status building looks up every project, so resolving each one with its own
    /// `ps` invocation meant well over a hundred process spawns per refresh. Take
    /// the snapshot once and answer all the lookups from memory instead.
    struct ProcessSnapshot {
        private let byPid: [Int32: String]

        static func capture() -> ProcessSnapshot {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "ps -axo pid=,command="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            var map: [Int32: String] = [:]
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let sep = trimmed.firstIndex(of: " "),
                      let pid = Int32(trimmed[trimmed.startIndex ..< sep]) else { continue }
                map[pid] = String(trimmed[trimmed.index(after: sep)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return ProcessSnapshot(byPid: map)
        }

        /// True when the pid's executable is the orch binary (guards against a
        /// recycled PID in a stale pid file).
        func isOrch(_ pid: Int32) -> Bool {
            guard let cmd = byPid[pid] else { return false }
            return Self.executableIsOrch(cmd)
        }

        /// Locate a project's orch process.
        ///
        /// A session is launched as `<bundle>/MacOS/orch <projectPath> [--continue]`,
        /// so an exact argument match identifies the project unambiguously. The
        /// bundle path (`<projectPath>/.orch/<name>.app/...`) is a fallback for
        /// sessions started without the path argument. Degenerate paths are
        /// rejected: a project registered at "/" would otherwise substring-match
        /// every orch bundle and claim an unrelated window.
        func orchPid(projectPath: String) -> Int32? {
            guard projectPath.count > 1 else { return nil }
            let marker = (projectPath as NSString).appendingPathComponent(".orch/")
            var markerMatch: Int32?
            for (pid, cmd) in byPid {
                guard Self.executableIsOrch(cmd) else { continue }
                if cmd.split(separator: " ").dropFirst().contains(where: { $0 == projectPath }) {
                    return pid
                }
                if markerMatch == nil, cmd.contains(marker) { markerMatch = pid }
            }
            return markerMatch
        }

        private static func executableIsOrch(_ cmd: String) -> Bool {
            let exe = cmd.split(separator: " ", maxSplits: 1).first.map(String.init) ?? cmd
            return (exe as NSString).lastPathComponent == "orch"
        }
    }

    /// Get running PID for a project path, resolved against a process snapshot.
    static func getRunningPid(projectPath: String, snapshot: ProcessSnapshot) -> Int32? {
        // Trust the pid file when it points at a live orch process.
        let pidFile = (projectPath as NSString).appendingPathComponent(".orch/orch.pid")
        if let content = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, isProcessRunning(pid) {
            if snapshot.isOrch(pid) { return pid }
            // Stale PID file — clean it up
            try? FileManager.default.removeItem(atPath: pidFile)
        }

        // Fall back to the snapshot, which also covers a missing/stale pid file.
        return snapshot.orchPid(projectPath: projectPath)
    }

    /// Convenience for one-off lookups; captures its own snapshot.
    static func getRunningPid(projectPath: String) -> Int32? {
        getRunningPid(projectPath: projectPath, snapshot: .capture())
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

    /// Resolve the absolute path to the `orch-clean` CLI — sibling of `orch`.
    ///
    /// Same reasoning as `orchExecutable()`: $PATH is stripped to a minimal
    /// default when the launcher runs as a Dock `.app`, so the sibling path is
    /// resolved explicitly rather than looked up.
    static func orchCleanExecutable() -> String {
        if let execPath = Bundle.main.executablePath {
            let execDir = (execPath as NSString).deletingLastPathComponent
            let candidate = (execDir as NSString)
                .appendingPathComponent("../bin/orch-clean")
            let resolved = (candidate as NSString).standardizingPath
            if FileManager.default.isExecutableFile(atPath: resolved) {
                return resolved
            }
        }
        return "orch-clean"
    }

    /// Run a command to completion and return (exitCode, stdout+stderr).
    ///
    /// Blocking on purpose: callers push this onto a background queue. A cleanup
    /// sweep walks every project with `du`, which takes seconds — long enough
    /// that running it on the main thread would freeze the panel.
    static func runCapturing(_ executable: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "could not run \(executable): \(error)") }
        // Drain BEFORE waiting: a sweep across 80 projects overflows the 64KB
        // pipe buffer, and a full buffer deadlocks the child mid-write.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// True if `path` exists and is a directory.
    static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
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
