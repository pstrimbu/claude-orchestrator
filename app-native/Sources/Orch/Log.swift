import Foundation

enum Log {
    private static var fileHandle: FileHandle?

    /// Past this size the log is moved to `orch-native.log.1` (replacing the
    /// previous one) at the next launch, so it can't grow without bound.
    static let maxBytes = 1_000_000

    /// Open the log for appending. It used to be truncated on every launch,
    /// which erased the record of whatever made the previous window close —
    /// exactly when it was needed (the F5 relaunch failure, 2026-11-16).
    static func setup(orchDir: String) {
        let path = orchDir + "/orch-native.log"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
            let old = path + ".1"
            try? fm.removeItem(atPath: old)
            try? fm.moveItem(atPath: path, toPath: old)
        }
        // O_APPEND: several windows of one project share this file, and each
        // write must land at the current end rather than at a remembered offset.
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        fileHandle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        log("=== orch-native started at \(Date()), pid \(getpid()) ===")
    }

    static func log(_ message: String) {
        let line = "[\(timeStr())] \(message)\n"
        fileHandle?.write(line.data(using: .utf8) ?? Data())
        // Also print for console debugging
        fputs(line, stderr)
    }

    private static func timeStr() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
