import Foundation

/// Reads the current Claude session's context size (token usage) from its
/// transcript JSONL. Claude Code writes one transcript per session at
/// ~/.claude/projects/<munged-project-path>/<sessionId>.jsonl and records
/// per-message `message.usage`. The context size for the latest turn is
/// input_tokens + cache_creation_input_tokens + cache_read_input_tokens — the
/// same figure Claude Code's own "context left" gauge uses.
///
/// Session UUIDs are globally unique across project dirs, so we locate the
/// transcript by globbing rather than replicating Claude's path munging.
struct SessionSize {
    let tokens: Int
    let model: String?
    let limit: Int
    var fraction: Double { limit > 0 ? Double(tokens) / Double(limit) : 0 }
}

/// Richer per-session metrics derived from the same transcript: context size
/// (as `SessionSize`), a running USD cost estimate, cumulative billed tokens
/// (for burn-rate sampling), and a best-effort count of in-flight background
/// agents (Task tool calls without a matching result yet).
struct SessionMetrics {
    let tokens: Int
    let model: String?
    let limit: Int
    let costUSD: Double
    let cumulativeTokens: Int
    let bgAgents: Int
    var fraction: Double { limit > 0 ? Double(tokens) / Double(limit) : 0 }
}

/// Per-million-token rates. Cache write is 1.25× input, cache read 0.1× input.
private struct ModelPricing {
    let input: Double, output: Double, cacheWrite: Double, cacheRead: Double
}

final class SessionSizeService {
    private var cachedPath: (sessionId: String, path: String)?
    private var cacheMtime: TimeInterval = -1
    private var cached: SessionSize?
    private var metricsMtime: TimeInterval = -1
    private var metricsCached: SessionMetrics?

    /// Context-window limit per model. This setup runs the 1M-context ([1m])
    /// tiers of these models; Haiku is 200k. Tune here if your tier differs.
    static func contextLimit(model: String?) -> Int {
        guard let m = model?.lowercased() else { return 1_000_000 }
        if m.contains("haiku") { return 200_000 }
        return 1_000_000
    }

    /// Read the latest context size for a session. Cheap to call repeatedly:
    /// re-parses only when the transcript's mtime changes, and reads just the
    /// tail of the file. Returns nil if no transcript/usage is found yet.
    func read(sessionId: String?) -> SessionSize? {
        guard let sessionId = sessionId, !sessionId.isEmpty else { return nil }
        guard let path = transcriptPath(sessionId: sessionId) else { return cached }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = attrs[.size] as? Int else { return cached }
        if mtime == cacheMtime, let c = cached { return c }

        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return cached }
        defer { try? fh.close() }

        // Read only the tail — the last usage-bearing line is near the end.
        let window = 1_000_000
        let start = size > window ? UInt64(size - window) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        // Lossy decode so a window that starts mid-UTF8 never yields nil; the
        // leading partial line is skipped by JSON parsing anyway.
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("input_tokens"),
                  let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = o["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let inp = usage["input_tokens"] as? Int ?? 0
            let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cr = usage["cache_read_input_tokens"] as? Int ?? 0
            let model = msg["model"] as? String
            let result = SessionSize(
                tokens: inp + cc + cr,
                model: model,
                limit: SessionSizeService.contextLimit(model: model)
            )
            cacheMtime = mtime
            cached = result
            return result
        }
        return cached
    }

    /// Approximate USD pricing per model (per-million-token rates from the
    /// Anthropic pricing table; tune here if your tier differs). Defaults to
    /// Opus-tier when the model is unknown.
    private static func pricing(model: String?) -> ModelPricing {
        let m = (model ?? "").lowercased()
        let inM: Double, outM: Double
        if m.contains("haiku") { inM = 1;  outM = 5 }
        else if m.contains("sonnet") { inM = 3;  outM = 15 }
        else if m.contains("fable") || m.contains("mythos") { inM = 10; outM = 50 }
        else { inM = 5;  outM = 25 }  // opus / default
        return ModelPricing(input: inM / 1e6, output: outM / 1e6,
                            cacheWrite: inM * 1.25 / 1e6, cacheRead: inM * 0.1 / 1e6)
    }

    /// Read cumulative session metrics from the transcript. Cost and burn need
    /// the whole file, so this reads more than `read()` (which only tails); it
    /// still re-parses only when the transcript's mtime changes. Returns nil if
    /// no transcript/usage exists yet.
    func readMetrics(sessionId: String?) -> SessionMetrics? {
        guard let sessionId = sessionId, !sessionId.isEmpty else { return nil }
        guard let path = transcriptPath(sessionId: sessionId) else { return metricsCached }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = attrs[.size] as? Int else { return metricsCached }
        if mtime == metricsMtime, let c = metricsCached { return c }

        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return metricsCached }
        defer { try? fh.close() }
        // Cap the read to the last 32 MB — cost/agents on a session older than
        // that are an estimate anyway, and this bounds parse time.
        let cap = 32 * 1024 * 1024
        let start = size > cap ? UInt64(size - cap) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)

        var cost = 0.0
        var cumulative = 0
        var contextTokens = 0
        var model: String?
        var taskIds = Set<String>()      // Task tool_use ids seen
        var resultIds = Set<String>()    // tool_result ids seen

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = o["message"] as? [String: Any] else { continue }

            if let usage = msg["usage"] as? [String: Any] {
                let inp = usage["input_tokens"] as? Int ?? 0
                let out = usage["output_tokens"] as? Int ?? 0
                let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cr = usage["cache_read_input_tokens"] as? Int ?? 0
                let lineModel = msg["model"] as? String
                let p = SessionSizeService.pricing(model: lineModel)
                cost += Double(inp) * p.input + Double(out) * p.output
                      + Double(cc) * p.cacheWrite + Double(cr) * p.cacheRead
                cumulative += inp + out + cc + cr
                contextTokens = inp + cc + cr  // last one wins
                if let lm = lineModel { model = lm }
            }

            // Track in-flight background agents: Task tool_use without a result.
            if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    let type = block["type"] as? String
                    if type == "tool_use", (block["name"] as? String) == "Task",
                       let id = block["id"] as? String {
                        taskIds.insert(id)
                    } else if type == "tool_result", let id = block["tool_use_id"] as? String {
                        resultIds.insert(id)
                    }
                }
            }
        }

        let bgAgents = taskIds.subtracting(resultIds).count
        let result = SessionMetrics(
            tokens: contextTokens,
            model: model,
            limit: SessionSizeService.contextLimit(model: model),
            costUSD: cost,
            cumulativeTokens: cumulative,
            bgAgents: bgAgents
        )
        metricsMtime = mtime
        metricsCached = result
        return result
    }

    private func transcriptPath(sessionId: String) -> String? {
        if let c = cachedPath, c.sessionId == sessionId,
           FileManager.default.fileExists(atPath: c.path) {
            return c.path
        }
        let base = NSHomeDirectory() + "/.claude/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let p = base + "/" + dir + "/" + sessionId + ".jsonl"
            if FileManager.default.fileExists(atPath: p) {
                cachedPath = (sessionId, p)
                return p
            }
        }
        return nil
    }
}
