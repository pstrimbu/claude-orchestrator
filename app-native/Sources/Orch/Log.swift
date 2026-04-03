import Foundation

enum Log {
    private static var fileHandle: FileHandle?

    static func setup(orchDir: String) {
        let path = orchDir + "/orch-native.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
        log("=== orch-native started at \(Date()) ===")
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
