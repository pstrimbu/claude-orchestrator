import Foundation

struct TrackerConfig: Codable {
    var type: String?  // "linear", "jira", "none"
    var title_prefix: String?
    var labels: [String]?
}

struct LinearConfig: Codable {
    var team_key: String?
    var project_name: String?
    var workflow: [String: String]?
    var labels: [String: String]?
    var auth: LinearAuth?

    struct LinearAuth: Codable {
        var api_key_env: String?
    }
}

struct JiraConfig: Codable {
    var project_key: String?
    var issue_type: String?
    var subtask_issue_type: String?
    var status: [String: String]?
    var labels: [String]?
    var auth: JiraAuth?

    struct JiraAuth: Codable {
        var base_url_env: String?
        var email_env: String?
        var api_token_env: String?
    }
}

struct ProjectJson: Codable {
    var project_id: String?
    var tracker: TrackerConfig?
    var linear: LinearConfig?
    var jira: JiraConfig?
}

class Config {
    let projectPath: String
    let projectName: String
    let orchDir: String
    private var projectJson: ProjectJson?

    init(projectPath: String) {
        self.projectPath = projectPath
        self.projectName = (projectPath as NSString).lastPathComponent
        self.orchDir = projectPath + "/.orch"
    }

    func loadProjectJson() -> ProjectJson {
        if let cached = projectJson { return cached }
        let loaded = readProjectJson()
        projectJson = loaded
        return loaded
    }

    private func readProjectJson() -> ProjectJson {
        let configPath = orchDir + "/project.json"
        guard FileManager.default.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONDecoder().decode(ProjectJson.self, from: data) else {
            return ProjectJson()
        }
        return json
    }

    func reload() {
        projectJson = nil
    }

    func save(updates: ProjectJson) {
        var existing = readProjectJson()
        if let pid = updates.project_id { existing.project_id = pid }
        if let t = updates.tracker { existing.tracker = t }
        if let l = updates.linear { existing.linear = l }
        if let j = updates.jira { existing.jira = j }

        try? FileManager.default.createDirectory(atPath: orchDir, withIntermediateDirectories: true)
        let configPath = orchDir + "/project.json"
        if let data = try? JSONEncoder().encode(existing) {
            var json = String(data: data, encoding: .utf8) ?? "{}"
            json += "\n"
            try? json.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        projectJson = existing
    }

    var projectId: String {
        loadProjectJson().project_id ?? projectName
    }

    var trackerType: String {
        let cfg = loadProjectJson()
        if let t = cfg.tracker?.type { return t }
        if cfg.linear?.team_key != nil { return "linear" }
        if cfg.jira?.project_key != nil { return "jira" }
        return "none"
    }

    var linearConfig: LinearConfig? { loadProjectJson().linear }
    var jiraConfig: JiraConfig? { loadProjectJson().jira }

    var trackerTitlePrefix: String {
        loadProjectJson().tracker?.title_prefix ?? "[AI]"
    }

    var clockifyApiKey: String? { ProcessInfo.processInfo.environment["CLOCKIFY_API_KEY"] }

    var clockifyWorkspaceId: String { "REDACTED-CLOCKIFY-WORKSPACE-ID" }
    var clockifyUserId: String { "REDACTED-CLOCKIFY-USER-ID" }

    var linearApiKey: String? {
        let envVar = linearConfig?.auth?.api_key_env ?? "LINEAR_API_KEY"
        return ProcessInfo.processInfo.environment[envVar]
    }

    var jiraBaseUrl: String? {
        let envVar = jiraConfig?.auth?.base_url_env ?? "JIRA_BASE_URL"
        return ProcessInfo.processInfo.environment[envVar]
    }

    var jiraEmail: String? {
        let envVar = jiraConfig?.auth?.email_env ?? "JIRA_EMAIL"
        return ProcessInfo.processInfo.environment[envVar]
    }

    var jiraApiToken: String? {
        let envVar = jiraConfig?.auth?.api_token_env ?? "JIRA_API_TOKEN"
        return ProcessInfo.processInfo.environment[envVar]
    }
}
