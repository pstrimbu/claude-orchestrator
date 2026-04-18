import Foundation

struct SessionInfo {
    let sessionId: String
    let firstMessage: String
    let lastTimestamp: Date
    let messageCount: Int
}

class SessionStore {
    let projectPath: String
    private var cache: [SessionInfo] = []
    private var cacheModTime: TimeInterval = 0

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    /// Get the current session ID by reading Claude's PID-based session file
    func currentSessionId(childPid: pid_t) -> String? {
        guard childPid > 0 else { return nil }
        let path = NSHomeDirectory() + "/.claude/sessions/\(childPid).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sessionId"] as? String
    }

    /// List recent sessions for this project from ~/.claude/history.jsonl
    func listSessions(limit: Int = 20) -> [SessionInfo] {
        let historyPath = NSHomeDirectory() + "/.claude/history.jsonl"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyPath),
              let modTime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return cache }

        if modTime == cacheModTime && !cache.isEmpty { return cache }
        cacheModTime = modTime

        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: historyPath)) else { return [] }
        let lines = String(decoding: fileData, as: UTF8.self).components(separatedBy: "\n")

        // Aggregate by sessionId, filtered to this project
        var sessionMap: [String: (first: String, last: TimeInterval, count: Int)] = [:]

        for line in lines.reversed() {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let project = json["project"] as? String,
                  project == projectPath,
                  let sessionId = json["sessionId"] as? String else { continue }

            let display = json["display"] as? String ?? ""
            let timestamp = json["timestamp"] as? TimeInterval ?? 0

            if var existing = sessionMap[sessionId] {
                existing.count += 1
                if timestamp < existing.last {
                    // This is an older entry — use it as first message
                    existing.first = display
                }
                sessionMap[sessionId] = existing
            } else {
                sessionMap[sessionId] = (first: display, last: timestamp, count: 1)
            }

            // Stop once we have enough unique sessions
            if sessionMap.count >= limit * 2 { break }
        }

        cache = sessionMap.map { id, info in
            SessionInfo(
                sessionId: id,
                firstMessage: info.first,
                lastTimestamp: Date(timeIntervalSince1970: info.last / 1000),
                messageCount: info.count
            )
        }
        .sorted { $0.lastTimestamp > $1.lastTimestamp }
        .prefix(limit)
        .map { $0 }

        return cache
    }
}
