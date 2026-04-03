import Foundation

class ClockifyService {
    private let config: Config
    private var clockifyProjectId: String?
    private(set) var recording = false
    private var startTime: Date?
    private var accumulated: TimeInterval = 0
    private var idleCheckTimer: Timer?
    private var eodCheckTimer: Timer?
    private var lastActivityTime: Date = .distantPast
    private var lastActivityDay: Int = -1
    private var summaryProvider: (() async -> String)?
    private var flushing = false

    private static let idleTimeoutS: TimeInterval = 60
    private static let flushThresholdS: TimeInterval = 30 * 60

    init(config: Config) {
        self.config = config
        eodCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkEndOfDay()
        }
    }

    func setSummaryProvider(_ provider: @escaping () async -> String) {
        summaryProvider = provider
    }

    var enabled: Bool { config.clockifyApiKey != nil }

    var elapsed: TimeInterval {
        if !recording || startTime == nil { return accumulated }
        return accumulated + Date().timeIntervalSince(startTime!)
    }

    func formatElapsed() -> String {
        let total = Int(elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        return "\(m)m"
    }

    func start() {
        guard !recording else { return }
        recording = true
        startTime = Date()
    }

    func stop() {
        guard recording else { return }
        if let st = startTime {
            accumulated += Date().timeIntervalSince(st)
        }
        recording = false
        startTime = nil
    }

    func onActivity() {
        lastActivityTime = Date()
        lastActivityDay = dayOfYear(Date())

        guard enabled else { return }

        if !recording { start() }

        if idleCheckTimer == nil {
            idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.checkIdle()
            }
        }

        if !flushing && elapsed >= Self.flushThresholdS {
            flushing = true
            Task {
                _ = try? await flush()
                await MainActor.run { self.flushing = false }
            }
        }
    }

    private func checkIdle() {
        guard recording else { return }
        let idle = Date().timeIntervalSince(lastActivityTime)
        if idle >= Self.idleTimeoutS {
            if let st = startTime {
                let activeEnd = lastActivityTime
                if activeEnd > st {
                    accumulated += activeEnd.timeIntervalSince(st)
                }
            }
            recording = false
            startTime = nil
        }
    }

    private func checkEndOfDay() {
        guard enabled, lastActivityDay >= 0 else { return }
        let today = dayOfYear(Date())
        guard today != lastActivityDay else { return }

        let seconds = elapsed
        if seconds >= 60 {
            Task { try? await flush(useLastActivity: true) }
        } else if seconds > 0 {
            accumulated = 0
            startTime = recording ? Date() : nil
        }
        lastActivityDay = today
    }

    private func dayOfYear(_ d: Date) -> Int {
        Calendar.current.ordinality(of: .day, in: .year, for: d) ?? 0
    }

    func flush(useLastActivity: Bool = false) async throws -> (success: Bool, entryId: String?, error: String?) {
        guard enabled else { return (false, nil, "Clockify not configured") }

        let seconds = elapsed
        guard seconds >= 60 else { return (false, nil, "Less than 1 minute accumulated") }

        var summary: String
        if let provider = summaryProvider {
            summary = await provider()
        } else {
            summary = "Active work on \(config.projectId)"
        }

        let end = (useLastActivity && lastActivityTime != .distantPast) ? lastActivityTime : Date()
        let start = end.addingTimeInterval(-seconds)

        do {
            let projectId = try await ensureProject()
            let entry = try await createTimeEntry(start: start, end: end, description: summary, projectId: projectId)
            accumulated = 0
            startTime = recording ? Date() : nil
            return (true, entry.id, nil)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    func getRecentEntries(limit: Int = 5) async -> [ClockifyTimeEntry] {
        guard enabled else { return [] }
        do {
            let projectId = try await ensureProject()
            let data = try await api("GET", path: "/workspaces/\(config.clockifyWorkspaceId)/user/\(config.clockifyUserId)/time-entries?page-size=\(limit)&project=\(projectId)")
            return (try? JSONDecoder().decode([ClockifyTimeEntry].self, from: data)) ?? []
        } catch { return [] }
    }

    private func ensureProject() async throws -> String {
        if let pid = clockifyProjectId { return pid }

        let encoded = config.projectId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.projectId
        let data = try await api("GET", path: "/workspaces/\(config.clockifyWorkspaceId)/projects?name=\(encoded)")
        let projects = (try? JSONDecoder().decode([ClockifyProject].self, from: data)) ?? []

        if let match = projects.first(where: { $0.name == config.projectId }) {
            clockifyProjectId = match.id
            return match.id
        }

        let body = try JSONEncoder().encode(["name": config.projectId])
        let createData = try await api("POST", path: "/workspaces/\(config.clockifyWorkspaceId)/projects", body: body)
        let created = try JSONDecoder().decode(ClockifyProject.self, from: createData)
        clockifyProjectId = created.id
        return created.id
    }

    private func createTimeEntry(start: Date, end: Date, description: String, projectId: String) async throws -> ClockifyTimeEntry {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body: [String: String] = [
            "start": formatter.string(from: start),
            "end": formatter.string(from: end),
            "description": description,
            "projectId": projectId,
        ]
        let bodyData = try JSONEncoder().encode(body)
        let data = try await api("POST", path: "/workspaces/\(config.clockifyWorkspaceId)/time-entries", body: bodyData)
        return try JSONDecoder().decode(ClockifyTimeEntry.self, from: data)
    }

    private func api(_ method: String, path: String, body: Data? = nil) async throws -> Data {
        let url = URL(string: "https://api.clockify.me/api/v1\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.clockifyApiKey!, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Clockify", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return data
    }

    func destroy() {
        stop()
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        eodCheckTimer?.invalidate()
        eodCheckTimer = nil
    }
}

struct ClockifyTimeEntry: Codable {
    let id: String
    var description: String?
    var timeInterval: ClockifyInterval?

    struct ClockifyInterval: Codable {
        var start: String?
        var end: String?
        var duration: String?
    }
}

struct ClockifyProject: Codable {
    let id: String
    let name: String
}
