import Foundation

/// Subscription accounts a session can run on (registry managed by `orch-account`).
///
///   ~/.config/orch/accounts.json             registry — no secrets
///   ~/.config/orch/accounts/<id>/            per-account config dir (CLAUDE_CONFIG_DIR /
///                                            CODEX_HOME); the CLI keeps its own login there
///   ~/.config/orch/accounts/<id>/usage.json  last known usage + limit, written by sessions
///
/// An account with no `dir` is the CLI's default login (~/.claude, ~/.codex).
struct Account {
    let id: String
    let type: String          // "claude" | "codex"
    let dir: String?
    let priority: Int
    let enabled: Bool

    /// Env for the agent process: point the CLI at this account's config dir.
    var env: [String: String?] {
        switch type {
        case "claude": return ["CLAUDE_CONFIG_DIR": dir]
        case "codex": return ["CODEX_HOME": dir]
        default: return [:]
        }
    }

    /// Where this account's Codex session logs live (for usage capture).
    var codexHome: String { dir ?? NSHomeDirectory() + "/.codex" }
}

struct AccountUsage {
    var fiveHourPct: Double?
    var fiveHourReset: Date?
    var weeklyPct: Double?
    var weeklyReset: Date?
    var limitedUntil: Date?

    var isLimited: Bool { (limitedUntil ?? .distantPast) > Date() }
}

enum AccountStore {
    static let root = NSHomeDirectory() + "/.config/orch"
    static var registryPath: String { root + "/accounts.json" }

    struct Registry {
        var policy: String        // "auto" | "confirm"
        var accounts: [Account]
    }

    static func load() -> Registry {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: registryPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Registry(policy: "confirm", accounts: [])
        }
        let policy = (obj["policy"] as? [String: Any])?["switch"] as? String ?? "confirm"
        let accounts = (obj["accounts"] as? [[String: Any]] ?? []).compactMap { a -> Account? in
            guard let id = a["id"] as? String, let type = a["type"] as? String else { return nil }
            return Account(id: id, type: type, dir: a["dir"] as? String,
                           priority: a["priority"] as? Int ?? 100,
                           enabled: a["enabled"] as? Bool ?? true)
        }
        return Registry(policy: policy, accounts: accounts)
    }

    /// The account type that drives a given agent CLI (LM Studio has none).
    static func type(for agent: Agent) -> String? {
        switch agent {
        case .claude: return "claude"
        case .codex: return "codex"
        case .lmstudio: return nil
        }
    }

    /// The account a session should use: the named one if it exists and matches
    /// the agent, else the highest-priority enabled account of that type.
    static func resolve(id: String?, agent: Agent) -> Account? {
        guard let type = type(for: agent) else { return nil }
        let all = load().accounts.filter { $0.type == type }
        if let id = id, let a = all.first(where: { $0.id == id }) { return a }
        return all.filter(\.enabled).min { $0.priority < $1.priority }
    }

    /// Next account to move to when `current` is limited: same type, enabled,
    /// not itself limited, by priority. Nil when every account of the type is out.
    static func next(after current: Account) -> Account? {
        load().accounts
            .filter { $0.type == current.type && $0.id != current.id && $0.enabled }
            .filter { !(readUsage($0.id)?.isLimited ?? false) }
            .min { $0.priority < $1.priority }
    }

    // MARK: - Usage

    static func usagePath(_ id: String) -> String { root + "/accounts/\(id)/usage.json" }

    static func readUsage(_ id: String) -> AccountUsage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: usagePath(id))),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func date(_ k: String) -> Date? { (o[k] as? Double).map { Date(timeIntervalSince1970: $0) } }
        return AccountUsage(fiveHourPct: o["five_hour_pct"] as? Double, fiveHourReset: date("five_hour_resets_at"),
                            weeklyPct: o["weekly_pct"] as? Double, weeklyReset: date("weekly_resets_at"),
                            limitedUntil: date("limited_until"))
    }

    static func writeUsage(_ id: String, _ u: AccountUsage, source: String) {
        var o: [String: Any] = ["account": id, "source": source,
                                "updated_at": Date().timeIntervalSince1970]
        if let v = u.fiveHourPct { o["five_hour_pct"] = v }
        if let v = u.fiveHourReset { o["five_hour_resets_at"] = v.timeIntervalSince1970 }
        if let v = u.weeklyPct { o["weekly_pct"] = v }
        if let v = u.weeklyReset { o["weekly_resets_at"] = v.timeIntervalSince1970 }
        if let v = u.limitedUntil { o["limited_until"] = v.timeIntervalSince1970 }
        let path = usagePath(id)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let tmp = path + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: data) { _ = rename(tmp, path) }
    }

    /// Usage as Claude Code reports it in the statusLine JSON (`rate_limits`).
    static func claudeUsage(statusLineFile: String) -> AccountUsage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusLineFile)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = o["rate_limits"] as? [String: Any] else { return nil }
        func window(_ k: String) -> (Double?, Date?) {
            let w = rl[k] as? [String: Any]
            return ((w?["used_percentage"] as? NSNumber)?.doubleValue,
                    (w?["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let (fp, fr) = window("five_hour"), (wp, wr) = window("seven_day")
        return AccountUsage(fiveHourPct: fp, fiveHourReset: fr, weeklyPct: wp, weeklyReset: wr)
    }

    /// Usage from the newest Codex session log for `cwd` started since `since`:
    /// the last `rate_limits` event (primary = the plan's window, secondary =
    /// a shorter one when the plan has it).
    static func codexUsage(codexHome: String, cwd: String, since: Date) -> AccountUsage? {
        let fm = FileManager.default
        let cal = Calendar.current
        var files: [(String, Date)] = []
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/sessions/%04d/%02d/%02d", codexHome, c.year!, c.month!, c.day!)
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                let p = dir + "/" + name
                if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, m >= since {
                    files.append((p, m))
                }
            }
        }
        for (path, _) in files.sorted(by: { $0.1 > $1.1 }) {
            guard let h = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? h.close() }
            // First line is session_meta; it names the working directory.
            let head = String(decoding: h.readData(ofLength: 16384), as: UTF8.self)
            // orch standardizes /private/tmp → /tmp; Codex logs the real path.
            guard head.contains("\"cwd\":\"\(cwd)\"") || head.contains("\"cwd\":\"/private\(cwd)\"")
            else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            guard let line = tail.split(separator: "\n").last(where: { $0.contains("\"rate_limits\"") }),
                  let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rl = findRateLimits(event) else { return nil }
            func window(_ k: String) -> (Double?, Date?, Int?) {
                let w = rl[k] as? [String: Any]
                return ((w?["used_percent"] as? NSNumber)?.doubleValue,
                        (w?["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                        (w?["window_minutes"] as? NSNumber)?.intValue)
            }
            // Map by window length: ≤ a day is the short window, longer is weekly.
            var u = AccountUsage()
            for k in ["primary", "secondary"] {
                let (pct, reset, mins) = window(k)
                guard pct != nil else { continue }
                if (mins ?? 10080) <= 1440 { u.fiveHourPct = pct; u.fiveHourReset = reset }
                else { u.weeklyPct = pct; u.weeklyReset = reset }
            }
            return u
        }
        return nil
    }

    private static func findRateLimits(_ o: Any) -> [String: Any]? {
        if let d = o as? [String: Any] {
            if let rl = d["rate_limits"] as? [String: Any] { return rl }
            for v in d.values { if let r = findRateLimits(v) { return r } }
        } else if let a = o as? [Any] {
            for v in a { if let r = findRateLimits(v) { return r } }
        }
        return nil
    }
}
