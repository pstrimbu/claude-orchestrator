import Foundation

struct HistoryEntry: Codable {
    let ts: String
    let cmd: String
    /// The Claude session (i.e. the orch window) this command was typed in.
    /// Nil for entries written before history was scoped per session — those are
    /// legacy and no longer surface in any window.
    var session: String?
}

/// Command history for a project, scoped per orch window.
///
/// The store is one append-only file per project, but every entry is tagged with
/// the window's Claude session id and reads are filtered to it. Two windows open
/// on the same project (which the "+" new-session chip makes easy) each see only
/// their own commands.
class CommandHistoryService {
    private let filePath: String
    private let flushPath: String
    private let legacyFlushPath: String

    /// Last Clockify flush per session id. Kept per session so one window
    /// flushing can't hide another window's unreported commands.
    private var flushTs: [String: String] = [:]
    /// Pre-upgrade global flush timestamp, used as a floor for sessions that have
    /// never flushed so upgrading doesn't re-report old commands.
    private var legacyFlushTs: String?

    init(orchDir: String) {
        try? FileManager.default.createDirectory(atPath: orchDir, withIntermediateDirectories: true)
        filePath = orchDir + "/command-history.jsonl"
        flushPath = orchDir + "/command-history-flushed.json"
        legacyFlushPath = orchDir + "/command-history-flushed.txt"

        if let data = try? Data(contentsOf: URL(fileURLWithPath: flushPath)),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            flushTs = map
        }
        if let text = try? String(contentsOfFile: legacyFlushPath, encoding: .utf8) {
            legacyFlushTs = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func append(_ cmd: String, session: String?) {
        let entry = HistoryEntry(ts: ISO8601DateFormatter().string(from: Date()), cmd: cmd, session: session)
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

    /// Recent commands typed in `session`. Returns nothing when the session id
    /// isn't known yet — better an empty list than another window's commands.
    func getRecent(_ n: Int = 50, session: String?) -> [HistoryEntry] {
        guard let session else { return [] }
        return Array(readAll().filter { $0.session == session }.suffix(n))
    }

    func getSinceLastFlush(session: String?) -> [HistoryEntry] {
        guard let session else { return [] }
        let entries = readAll().filter { $0.session == session }
        guard let ts = flushTs[session] ?? legacyFlushTs else { return entries }
        return entries.filter { $0.ts > ts }
    }

    func markFlushed(session: String?) {
        guard let session else { return }
        flushTs[session] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONEncoder().encode(flushTs) {
            try? data.write(to: URL(fileURLWithPath: flushPath), options: .atomic)
        }
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
