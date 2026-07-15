import Foundation

/// Reads the current session's live metrics from the JSON Claude Code reports
/// via its `statusLine` hook (see `ClaudeSession.statusSettings()`), rather than
/// parsing the session transcript.
///
/// Why: the Claude Code docs state the transcript format is "internal to Claude
/// Code and changes between versions, so scripts that parse these files directly
/// can break on any release." The statusLine payload is a documented contract,
/// and its numbers are authoritative — `cost.total_cost_usd` and
/// `context_window.used_percentage` come from Claude's own accounting rather
/// than our re-derivation of it.
///
/// Claude rewrites the file after every assistant message and after `/compact`
/// finishes, so polling it is cheap and picks up compaction for free.
struct SessionMetrics {
    let tokens: Int              // tokens currently in the context window
    let model: String?           // display name, e.g. "Opus"
    let limit: Int               // context_window_size
    let costUSD: Double          // Claude's own client-side estimate
    let bgAgents: Int            // in-flight subagents
    /// Claude's pre-calculated percentage. Nil early in a session and right
    /// after `/compact`, until the next API call repopulates usage.
    let usedPercentage: Double?

    var fraction: Double {
        if let p = usedPercentage { return p / 100 }
        return limit > 0 ? Double(tokens) / Double(limit) : 0
    }
}

final class SessionSizeService {
    private var statusMtime: TimeInterval = -1
    private var subagentMtime: TimeInterval = -1
    private var cached: SessionMetrics?
    private var cachedAgents = 0

    /// Read the latest metrics for a project's session. Cheap to call
    /// repeatedly: re-parses only when Claude has rewritten the file. Returns
    /// nil until the first assistant message produces a status payload.
    func read(projectPath: String) -> SessionMetrics? {
        let agents = readAgents(projectPath: projectPath)

        let path = ClaudeSession.statusFile(projectPath: projectPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return cached }

        // The agent count changes independently of the main payload, so refresh
        // it on the cached path too rather than reporting a stale count.
        if mtime == statusMtime, let c = cached {
            guard agents != c.bgAgents else { return c }
            let updated = SessionMetrics(
                tokens: c.tokens, model: c.model, limit: c.limit, costUSD: c.costUSD,
                bgAgents: agents, usedPercentage: c.usedPercentage
            )
            cached = updated
            return updated
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return cached }

        let ctx = o["context_window"] as? [String: Any]
        let cost = o["cost"] as? [String: Any]
        let model = o["model"] as? [String: Any]

        let result = SessionMetrics(
            tokens: ctx?["total_input_tokens"] as? Int ?? 0,
            model: model?["display_name"] as? String ?? model?["id"] as? String,
            // 200k default, 1M for extended-context models — Claude tells us which.
            limit: ctx?["context_window_size"] as? Int ?? 200_000,
            costUSD: cost?["total_cost_usd"] as? Double ?? 0,
            bgAgents: agents,
            usedPercentage: ctx?["used_percentage"] as? Double
        )
        statusMtime = mtime
        cached = result
        return result
    }

    /// Count in-flight subagents from the `subagentStatusLine` payload. Claude
    /// only runs that command while agent rows are visible, so a payload that
    /// has gone stale relative to the main status file means the panel is gone —
    /// report zero rather than pinning the last count on screen forever.
    private func readAgents(projectPath: String) -> Int {
        let path = ClaudeSession.subagentFile(projectPath: projectPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return 0 }

        let statusPath = ClaudeSession.statusFile(projectPath: projectPath)
        if let sAttrs = try? FileManager.default.attributesOfItem(atPath: statusPath),
           let sMtime = (sAttrs[.modificationDate] as? Date)?.timeIntervalSince1970,
           sMtime > mtime + 5 {
            return 0
        }

        if mtime == subagentMtime { return cachedAgents }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = o["tasks"] as? [[String: Any]]
        else { return cachedAgents }

        let running = tasks.filter { t in
            let s = (t["status"] as? String ?? "").lowercased()
            return s != "completed" && s != "failed" && s != "cancelled"
        }.count

        subagentMtime = mtime
        cachedAgents = running
        return running
    }
}
