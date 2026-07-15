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

    /// Get the current session ID for this window's Claude process.
    ///
    /// Claude Code *usually* writes ~/.claude/sessions/<pid>.json mapping its pid
    /// to a sessionId, but not always — plenty of live sessions have no such file.
    /// Returning nil there blanks the model/size/cost chips for the life of the
    /// window (nothing ever re-populates them, because the file never appears), so
    /// fall back to resolving by project instead of giving up.
    func currentSessionId(childPid: pid_t) -> String? {
        if childPid > 0, let id = sessionIdFromPidFile(childPid) { return id }
        if let id = sessionIdFromCwdMatch() { return id }
        return sessionIdFromLatestTranscript()
    }

    /// Primary: the pid -> sessionId file Claude writes for this exact process.
    private func sessionIdFromPidFile(_ pid: pid_t) -> String? {
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sessionId"] as? String
    }

    /// Fallback: any *live* session whose `cwd` is this project. Covers the case
    /// where Claude recorded a session file under a pid we don't track.
    private func sessionIdFromCwdMatch() -> String? {
        let dir = NSHomeDirectory() + "/.claude/sessions"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (updated: Double, id: String)?
        for f in files where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + f)),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  j["cwd"] as? String == projectPath,
                  let id = j["sessionId"] as? String else { continue }
            // Skip sessions whose process is gone — their transcript is stale.
            if let pid = j["pid"] as? Int, kill(pid_t(pid), 0) != 0 { continue }
            let updated = j["updatedAt"] as? Double ?? 0
            if best == nil || updated > best!.updated { best = (updated, id) }
        }
        return best?.id
    }

    /// Last resort: newest transcript in this project's transcript dir. Claude
    /// munges the project path into the dir name by replacing "/", "." and "_"
    /// with "-" (e.g. /Users/me/dev/a.b.com -> -Users-me-dev-a-b-com).
    private func sessionIdFromLatestTranscript() -> String? {
        let munged = projectPath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let dir = NSHomeDirectory() + "/.claude/projects/" + munged
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (mtime: Date, id: String)?
        for f in files where f.hasSuffix(".jsonl") {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/" + f),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if best == nil || m > best!.mtime { best = (m, String(f.dropLast(6))) }
        }
        return best?.id
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
