import Foundation

struct HistoryEntry: Codable {
    let ts: String
    let cmd: String
}

class CommandHistoryService {
    private let filePath: String
    private let flushTsPath: String
    private(set) var lastFlushTs: String?

    init(orchDir: String) {
        try? FileManager.default.createDirectory(atPath: orchDir, withIntermediateDirectories: true)
        filePath = orchDir + "/command-history.jsonl"
        flushTsPath = orchDir + "/command-history-flushed.txt"

        if let data = try? String(contentsOfFile: flushTsPath, encoding: .utf8) {
            lastFlushTs = data.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func append(_ cmd: String) {
        let entry = HistoryEntry(ts: ISO8601DateFormatter().string(from: Date()), cmd: cmd)
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let handle: FileHandle
        if FileManager.default.fileExists(atPath: filePath) {
            guard let fh = FileHandle(forWritingAtPath: filePath) else { return }
            handle = fh
            handle.seekToEndOfFile()
        } else {
            FileManager.default.createFile(atPath: filePath, contents: nil)
            guard let fh = FileHandle(forWritingAtPath: filePath) else { return }
            handle = fh
        }
        handle.write((line + "\n").data(using: .utf8)!)
        handle.closeFile()
    }

    func getRecent(_ n: Int = 50) -> [HistoryEntry] {
        Array(readAll().suffix(n))
    }

    func getSinceLastFlush() -> [HistoryEntry] {
        guard let ts = lastFlushTs else { return readAll() }
        return readAll().filter { $0.ts > ts }
    }

    func markFlushed() {
        let ts = ISO8601DateFormatter().string(from: Date())
        lastFlushTs = ts
        try? ts.write(toFile: flushTsPath, atomically: true, encoding: .utf8)
    }

    private func readAll() -> [HistoryEntry] {
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        return contents.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(HistoryEntry.self, from: data)
            }
    }
}
