import Foundation

struct Issue {
    let id: String
    let key: String
    var title: String
    var status: String
    let priority: String
    let url: String
    var assignee: String?
}

protocol TrackerService {
    var type: String { get }
    var enabled: Bool { get }
    var teamKey: String { get }
    func listIssues(status: String?, assignedToMe: Bool, limit: Int) async throws -> [Issue]
    func getIssue(key: String) async throws -> Issue?
    func updateStatus(key: String, status: String) async throws
    func addComment(key: String, comment: String) async throws
    func createIssue(title: String, description: String) async throws -> Issue
}

// MARK: - Linear

class LinearTracker: TrackerService {
    let type = "linear"
    let enabled: Bool
    let teamKey: String
    private let apiKey: String
    private let config: Config

    init(config: Config) {
        self.config = config
        self.enabled = config.linearApiKey != nil && config.linearConfig?.team_key != nil
        self.teamKey = config.linearConfig?.team_key ?? ""
        self.apiKey = config.linearApiKey ?? ""
    }

    func listIssues(status: String? = nil, assignedToMe: Bool = false, limit: Int = 25) async throws -> [Issue] {
        var filter: [String: Any] = [
            "team": ["key": ["eq": teamKey]],
            "state": ["type": ["nin": ["completed", "canceled"]]],
        ]
        if assignedToMe { filter["assignee"] = ["isMe": ["eq": true]] }

        let query = """
        query($filter: IssueFilter, $first: Int) {
          issues(filter: $filter, first: $first, orderBy: updatedAt) {
            nodes { id identifier title url state { name } priority priorityLabel assignee { name } }
          }
        }
        """
        let data = try await gql(query: query, variables: ["filter": filter, "first": limit])
        guard let issues = data["issues"] as? [String: Any],
              let nodes = issues["nodes"] as? [[String: Any]] else { return [] }

        return nodes.map { n in
            Issue(
                id: n["id"] as? String ?? "",
                key: n["identifier"] as? String ?? "",
                title: n["title"] as? String ?? "",
                status: (n["state"] as? [String: Any])?["name"] as? String ?? "Unknown",
                priority: n["priorityLabel"] as? String ?? "None",
                url: n["url"] as? String ?? "",
                assignee: (n["assignee"] as? [String: Any])?["name"] as? String
            )
        }
    }

    func getIssue(key: String) async throws -> Issue? {
        let query = """
        query($key: String!) {
          issueSearch(query: $key, first: 1) {
            nodes { id identifier title url state { name } priority priorityLabel assignee { name } }
          }
        }
        """
        let data = try await gql(query: query, variables: ["key": key])
        guard let search = data["issueSearch"] as? [String: Any],
              let nodes = search["nodes"] as? [[String: Any]],
              let n = nodes.first else { return nil }

        return Issue(
            id: n["id"] as? String ?? "",
            key: n["identifier"] as? String ?? "",
            title: n["title"] as? String ?? "",
            status: (n["state"] as? [String: Any])?["name"] as? String ?? "Unknown",
            priority: n["priorityLabel"] as? String ?? "None",
            url: n["url"] as? String ?? "",
            assignee: (n["assignee"] as? [String: Any])?["name"] as? String
        )
    }

    func updateStatus(key: String, status: String) async throws {
        guard let issue = try await getIssue(key: key) else {
            throw NSError(domain: "Linear", code: 404, userInfo: [NSLocalizedDescriptionKey: "Issue \(key) not found"])
        }

        let statesQuery = """
        query($teamKey: String!) {
          teams(filter: { key: { eq: $teamKey } }) {
            nodes { states { nodes { id name } } }
          }
        }
        """
        let statesData = try await gql(query: statesQuery, variables: ["teamKey": teamKey])
        guard let teams = statesData["teams"] as? [String: Any],
              let teamNodes = teams["nodes"] as? [[String: Any]],
              let states = (teamNodes.first?["states"] as? [String: Any])?["nodes"] as? [[String: Any]] else {
            throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not fetch states"])
        }

        guard let target = states.first(where: { ($0["name"] as? String)?.lowercased() == status.lowercased() }) else {
            throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: "State \"\(status)\" not found"])
        }

        _ = try await gql(
            query: "mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }",
            variables: ["id": issue.id, "stateId": target["id"] as? String ?? ""]
        )
    }

    func addComment(key: String, comment: String) async throws {
        guard let issue = try await getIssue(key: key) else {
            throw NSError(domain: "Linear", code: 404, userInfo: [NSLocalizedDescriptionKey: "Issue \(key) not found"])
        }
        _ = try await gql(
            query: "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success } }",
            variables: ["issueId": issue.id, "body": comment]
        )
    }

    func createIssue(title: String, description: String) async throws -> Issue {
        let teamQuery = "query($key: String!) { teams(filter: { key: { eq: $key } }) { nodes { id } } }"
        let teamData = try await gql(query: teamQuery, variables: ["key": teamKey])
        guard let teams = teamData["teams"] as? [String: Any],
              let nodes = teams["nodes"] as? [[String: Any]],
              let teamId = nodes.first?["id"] as? String else {
            throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: "Team \(teamKey) not found"])
        }

        let prefix = config.trackerTitlePrefix
        let mutation = """
        mutation($teamId: String!, $title: String!, $description: String) {
          issueCreate(input: { teamId: $teamId, title: $title, description: $description }) {
            success issue { id identifier title url state { name } priorityLabel }
          }
        }
        """
        let data = try await gql(query: mutation, variables: ["teamId": teamId, "title": "\(prefix) \(title)", "description": description])
        guard let create = data["issueCreate"] as? [String: Any],
              let n = create["issue"] as? [String: Any] else {
            throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to create issue"])
        }

        return Issue(
            id: n["id"] as? String ?? "",
            key: n["identifier"] as? String ?? "",
            title: n["title"] as? String ?? "",
            status: (n["state"] as? [String: Any])?["name"] as? String ?? "Backlog",
            priority: n["priorityLabel"] as? String ?? "None",
            url: n["url"] as? String ?? ""
        )
    }

    private func gql(query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        let url = URL(string: "https://api.linear.app/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Linear", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }
        if let errors = json["errors"] as? [[String: Any]], let msg = errors.first?["message"] as? String {
            throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return json["data"] as? [String: Any] ?? [:]
    }
}

// MARK: - Jira

class JiraTracker: TrackerService {
    let type = "jira"
    let enabled: Bool
    let teamKey: String
    private let baseUrl: String
    private let authHeader: String
    private let config: Config

    init(config: Config) {
        self.config = config
        self.enabled = config.jiraBaseUrl != nil && config.jiraEmail != nil && config.jiraApiToken != nil
        self.teamKey = config.jiraConfig?.project_key ?? ""
        self.baseUrl = config.jiraBaseUrl ?? ""
        let creds = "\(config.jiraEmail ?? ""):\(config.jiraApiToken ?? "")"
        self.authHeader = "Basic \(Data(creds.utf8).base64EncodedString())"
    }

    func listIssues(status: String? = nil, assignedToMe: Bool = false, limit: Int = 25) async throws -> [Issue] {
        var jql = "project = \(teamKey) AND status != Done"
        if assignedToMe { jql += " AND assignee = currentUser()" }
        if let s = status { jql += " AND status = \"\(s)\"" }
        jql += " ORDER BY updated DESC"

        let encoded = jql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? jql
        let data = try await api("GET", path: "/search?jql=\(encoded)&maxResults=\(limit)&fields=summary,status,priority,assignee")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issues = json["issues"] as? [[String: Any]] else { return [] }

        return issues.map { i in
            let fields = i["fields"] as? [String: Any] ?? [:]
            let key = i["key"] as? String ?? ""
            return Issue(
                id: i["id"] as? String ?? "",
                key: key,
                title: fields["summary"] as? String ?? "",
                status: (fields["status"] as? [String: Any])?["name"] as? String ?? "Unknown",
                priority: (fields["priority"] as? [String: Any])?["name"] as? String ?? "None",
                url: "\(baseUrl)/browse/\(key)",
                assignee: (fields["assignee"] as? [String: Any])?["displayName"] as? String
            )
        }
    }

    func getIssue(key: String) async throws -> Issue? {
        let data = try await api("GET", path: "/issue/\(key)?fields=summary,status,priority,assignee")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fields = json["fields"] as? [String: Any] ?? [:]
        let k = json["key"] as? String ?? key
        return Issue(
            id: json["id"] as? String ?? "",
            key: k,
            title: fields["summary"] as? String ?? "",
            status: (fields["status"] as? [String: Any])?["name"] as? String ?? "Unknown",
            priority: (fields["priority"] as? [String: Any])?["name"] as? String ?? "None",
            url: "\(baseUrl)/browse/\(k)",
            assignee: (fields["assignee"] as? [String: Any])?["displayName"] as? String
        )
    }

    func updateStatus(key: String, status: String) async throws {
        let data = try await api("GET", path: "/issue/\(key)/transitions")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transitions = json["transitions"] as? [[String: Any]] else { return }

        let semanticMap = config.jiraConfig?.status ?? [:]
        let targetName = semanticMap[status] ?? status
        guard let transition = transitions.first(where: {
            ($0["name"] as? String)?.lowercased() == targetName.lowercased() ||
            (($0["to"] as? [String: Any])?["name"] as? String)?.lowercased() == targetName.lowercased()
        }) else {
            throw NSError(domain: "Jira", code: 0, userInfo: [NSLocalizedDescriptionKey: "Transition to \"\(status)\" not available"])
        }

        let body = try JSONSerialization.data(withJSONObject: ["transition": ["id": transition["id"]]])
        _ = try await api("POST", path: "/issue/\(key)/transitions", body: body)
    }

    func addComment(key: String, comment: String) async throws {
        let adf: [String: Any] = [
            "body": [
                "type": "doc", "version": 1,
                "content": [["type": "paragraph", "content": [["type": "text", "text": comment]]]]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: adf)
        _ = try await api("POST", path: "/issue/\(key)/comment", body: body)
    }

    func createIssue(title: String, description: String) async throws -> Issue {
        let prefix = config.trackerTitlePrefix
        let issueType = config.jiraConfig?.issue_type ?? "Task"
        let fields: [String: Any] = [
            "fields": [
                "project": ["key": teamKey],
                "summary": "\(prefix) \(title)",
                "issuetype": ["name": issueType],
                "description": [
                    "type": "doc", "version": 1,
                    "content": [["type": "paragraph", "content": [["type": "text", "text": description]]]]
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: fields)
        let data = try await api("POST", path: "/issue", body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Jira", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        let key = json["key"] as? String ?? ""
        return Issue(
            id: json["id"] as? String ?? "",
            key: key,
            title: "\(prefix) \(title)",
            status: "To Do",
            priority: "Medium",
            url: "\(baseUrl)/browse/\(key)"
        )
    }

    private func api(_ method: String, path: String, body: Data? = nil) async throws -> Data {
        let url = URL(string: "\(baseUrl)/rest/api/3\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            throw NSError(domain: "Jira", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }
        return data
    }
}

// MARK: - Null

class NullTracker: TrackerService {
    let type = "none"
    let enabled = false
    let teamKey = ""
    func listIssues(status: String?, assignedToMe: Bool, limit: Int) async throws -> [Issue] { [] }
    func getIssue(key: String) async throws -> Issue? { nil }
    func updateStatus(key: String, status: String) async throws {}
    func addComment(key: String, comment: String) async throws {}
    func createIssue(title: String, description: String) async throws -> Issue {
        throw NSError(domain: "Tracker", code: 0, userInfo: [NSLocalizedDescriptionKey: "No tracker configured"])
    }
}

func createTracker(config: Config) -> TrackerService {
    switch config.trackerType {
    case "linear": return LinearTracker(config: config)
    case "jira": return JiraTracker(config: config)
    default: return NullTracker()
    }
}
