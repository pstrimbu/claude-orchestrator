import Foundation

func showTrackerSetup(overlay: OverlayManager, config: Config, onConfigured: @escaping () -> Void, onUpdate: @escaping () -> Void) {
    overlay.show(OverlayConfig(
        title: "Configure Issue Tracker",
        items: [
            OverlayItem(label: "Select tracker type:", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "[L] Linear", shortcut: "l", action: {
                setupLinear(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
            }),
            OverlayItem(label: "[J] Jira", shortcut: "j", action: {
                setupJira(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
            }),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "[N] No tracker", shortcut: "n", action: {
                config.save(updates: ProjectJson(tracker: TrackerConfig(type: "none")))
                onConfigured()
                overlay.showMessage("Tracker disabled")
            }),
        ],
        onClose: onUpdate,
        footer: "[L] Linear  [J] Jira  [N] None"
    ))
}

private func setupLinear(overlay: OverlayManager, config: Config, onConfigured: @escaping () -> Void, onUpdate: @escaping () -> Void) {
    guard let apiKey = ProcessInfo.processInfo.environment["LINEAR_API_KEY"] else {
        overlay.updateItems([
            OverlayItem(label: "LINEAR_API_KEY not found in environment", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "To set up Linear:", dimmed: true),
            OverlayItem(label: "  1. Get an API key from Linear Settings > API", dimmed: true),
            OverlayItem(label: "  2. Add to your .env file:", dimmed: true),
            OverlayItem(label: "     LINEAR_API_KEY=lin_api_xxxxx", dimmed: true),
            OverlayItem(label: "  3. Restart orch", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
            }),
        ])
        return
    }

    overlay.setLoading(true)
    Task {
        do {
            let teams = try await fetchLinearTeams(apiKey: apiKey)
            await MainActor.run {
                overlay.setLoading(false)
                if teams.isEmpty {
                    overlay.updateItems([
                        OverlayItem(label: "No teams found in your Linear workspace", dimmed: true),
                        OverlayItem(label: "", dimmed: true),
                        OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                            showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                        }),
                    ])
                    return
                }

                var items: [OverlayItem] = [
                    OverlayItem(label: "Select your Linear team:", dimmed: true),
                    OverlayItem(label: "", dimmed: true),
                ]
                for team in teams {
                    items.append(OverlayItem(label: "\(team.key) \u{2014} \(team.name)", action: {
                        pickLinearProject(overlay: overlay, config: config, apiKey: apiKey, team: team, onConfigured: onConfigured, onUpdate: onUpdate)
                    }))
                }
                items.append(OverlayItem(label: "", dimmed: true))
                items.append(OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                    showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                }))
                overlay.updateItems(items)
            }
        } catch {
            await MainActor.run {
                overlay.setLoading(false)
                overlay.updateItems([
                    OverlayItem(label: "Error connecting to Linear: \(error.localizedDescription)", dimmed: true),
                    OverlayItem(label: "", dimmed: true),
                    OverlayItem(label: "[R] Retry", shortcut: "r", action: {
                        setupLinear(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                    }),
                    OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                        showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                    }),
                ])
            }
        }
    }
}

private struct LinearTeamInfo { let id: String; let key: String; let name: String }
private struct LinearProjectInfo { let id: String; let name: String }

private func fetchLinearTeams(apiKey: String) async throws -> [LinearTeamInfo] {
    let data = try await linearGql(apiKey: apiKey, query: "query { teams { nodes { id key name } } }")
    guard let teams = data["teams"] as? [String: Any],
          let nodes = teams["nodes"] as? [[String: Any]] else { return [] }
    return nodes.map { LinearTeamInfo(id: $0["id"] as? String ?? "", key: $0["key"] as? String ?? "", name: $0["name"] as? String ?? "") }
}

private func pickLinearProject(overlay: OverlayManager, config: Config, apiKey: String, team: LinearTeamInfo, onConfigured: @escaping () -> Void, onUpdate: @escaping () -> Void) {
    overlay.setLoading(true)
    Task {
        do {
            let data = try await linearGql(apiKey: apiKey, query: """
            query($teamId: String!) {
              team(id: $teamId) {
                projects { nodes { id name } }
                states { nodes { id name type } }
              }
            }
            """, variables: ["teamId": team.id])

            let teamData = data["team"] as? [String: Any] ?? [:]
            let projects = ((teamData["projects"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).map {
                LinearProjectInfo(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "")
            }
            let states = ((teamData["states"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])

            var workflow: [String: String] = [:]
            for state in states {
                switch state["type"] as? String {
                case "backlog": workflow["queued"] = state["name"] as? String
                case "started": workflow["in_progress"] = state["name"] as? String
                case "completed": workflow["done"] = state["name"] as? String
                case "cancelled": workflow["abandoned"] = state["name"] as? String
                default: break
                }
            }

            await MainActor.run {
                overlay.setLoading(false)
                var items: [OverlayItem] = [
                    OverlayItem(label: "Team: \(team.key) \u{2014} \(team.name)", dimmed: true),
                    OverlayItem(label: "", dimmed: true),
                ]

                if !projects.isEmpty {
                    items.append(OverlayItem(label: "Link to a Linear project (optional):", dimmed: true))
                    items.append(OverlayItem(label: "", dimmed: true))
                    items.append(OverlayItem(label: "No project (team-level issues only)", action: {
                        saveLinearConfig(config: config, team: team, project: nil, workflow: workflow, onConfigured: onConfigured, overlay: overlay)
                    }))
                    for project in projects {
                        items.append(OverlayItem(label: project.name, action: {
                            saveLinearConfig(config: config, team: team, project: project, workflow: workflow, onConfigured: onConfigured, overlay: overlay)
                        }))
                    }
                } else {
                    items.append(OverlayItem(label: "Save configuration", action: {
                        saveLinearConfig(config: config, team: team, project: nil, workflow: workflow, onConfigured: onConfigured, overlay: overlay)
                    }))
                }

                items.append(OverlayItem(label: "", dimmed: true))
                items.append(OverlayItem(label: "\u{2190} Back to teams", shortcut: "b", action: {
                    setupLinear(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                }))
                overlay.updateItems(items)
            }
        } catch {
            await MainActor.run {
                overlay.setLoading(false)
                overlay.showMessage("Error: \(error.localizedDescription)")
            }
        }
    }
}

private func saveLinearConfig(config: Config, team: LinearTeamInfo, project: LinearProjectInfo?, workflow: [String: String], onConfigured: @escaping () -> Void, overlay: OverlayManager) {
    config.save(updates: ProjectJson(
        tracker: TrackerConfig(type: "linear", title_prefix: "[AI]"),
        linear: LinearConfig(
            team_key: team.key,
            project_name: project?.name,
            workflow: workflow,
            auth: LinearConfig.LinearAuth(api_key_env: "LINEAR_API_KEY")
        )
    ))

    onConfigured()
    let msg = project != nil ? "Configured: \(team.key) / \(project!.name)" : "Configured: \(team.key)"
    overlay.showMessage(msg)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        var items: [OverlayItem] = [
            OverlayItem(label: "\u{2713} Linear configured!", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "Team: \(team.key) \u{2014} \(team.name)", dimmed: true),
        ]
        if let p = project {
            items.append(OverlayItem(label: "Project: \(p.name)", dimmed: true))
        }
        items += [
            OverlayItem(label: "Config saved to .orch/project.json", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "Press Esc to close", dimmed: true),
        ]
        overlay.updateItems(items)
    }
}

private func setupJira(overlay: OverlayManager, config: Config, onConfigured: @escaping () -> Void, onUpdate: @escaping () -> Void) {
    let env = ProcessInfo.processInfo.environment
    let baseUrl = env["JIRA_BASE_URL"]
    let email = env["JIRA_EMAIL"]
    let token = env["JIRA_API_TOKEN"]

    guard let baseUrl = baseUrl, let email = email, let token = token else {
        var missing: [String] = []
        if baseUrl == nil { missing.append("JIRA_BASE_URL") }
        if email == nil { missing.append("JIRA_EMAIL") }
        if token == nil { missing.append("JIRA_API_TOKEN") }

        var items: [OverlayItem] = [OverlayItem(label: "Missing Jira environment variables:", dimmed: true), OverlayItem(label: "", dimmed: true)]
        for v in missing { items.append(OverlayItem(label: "  \u{2717} \(v)", dimmed: true)) }
        items += [
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "Add these to your .env file and restart orch", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
            }),
        ]
        overlay.updateItems(items)
        return
    }

    overlay.setLoading(true)
    Task {
        do {
            let auth = Data("\(email):\(token)".utf8).base64EncodedString()
            let url = URL(string: "\(baseUrl)/rest/api/3/project/search?maxResults=50")!
            var request = URLRequest(url: url)
            request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let projects = json["values"] as? [[String: Any]] else { return }

            await MainActor.run {
                overlay.setLoading(false)
                if projects.isEmpty {
                    overlay.updateItems([
                        OverlayItem(label: "No projects found in Jira", dimmed: true),
                        OverlayItem(label: "", dimmed: true),
                        OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                            showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                        }),
                    ])
                    return
                }

                var items: [OverlayItem] = [
                    OverlayItem(label: "Select your Jira project:", dimmed: true),
                    OverlayItem(label: "", dimmed: true),
                ]
                for proj in projects {
                    let key = proj["key"] as? String ?? ""
                    let name = proj["name"] as? String ?? ""
                    items.append(OverlayItem(label: "\(key) \u{2014} \(name)", action: {
                        config.save(updates: ProjectJson(
                            tracker: TrackerConfig(type: "jira", title_prefix: "[AI]"),
                            jira: JiraConfig(
                                project_key: key, issue_type: "Task", subtask_issue_type: "Sub-task",
                                status: ["todo": "To Do", "in_progress": "In Progress", "done": "Done"],
                                auth: JiraConfig.JiraAuth(base_url_env: "JIRA_BASE_URL", email_env: "JIRA_EMAIL", api_token_env: "JIRA_API_TOKEN")
                            )
                        ))
                        onConfigured()
                        overlay.showMessage("Configured: \(key)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            overlay.updateItems([
                                OverlayItem(label: "\u{2713} Jira configured!", dimmed: true),
                                OverlayItem(label: "", dimmed: true),
                                OverlayItem(label: "Project: \(key) \u{2014} \(name)", dimmed: true),
                                OverlayItem(label: "Config saved to .orch/project.json", dimmed: true),
                                OverlayItem(label: "", dimmed: true),
                                OverlayItem(label: "Press Esc to close", dimmed: true),
                            ])
                        }
                    }))
                }
                items.append(OverlayItem(label: "", dimmed: true))
                items.append(OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                    showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                }))
                overlay.updateItems(items)
            }
        } catch {
            await MainActor.run {
                overlay.setLoading(false)
                overlay.updateItems([
                    OverlayItem(label: "Error connecting to Jira: \(error.localizedDescription)", dimmed: true),
                    OverlayItem(label: "", dimmed: true),
                    OverlayItem(label: "[R] Retry", shortcut: "r", action: {
                        setupJira(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                    }),
                    OverlayItem(label: "\u{2190} Back", shortcut: "b", action: {
                        showTrackerSetup(overlay: overlay, config: config, onConfigured: onConfigured, onUpdate: onUpdate)
                    }),
                ])
            }
        }
    }
}

private func linearGql(apiKey: String, query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
    let url = URL(string: "https://api.linear.app/graphql")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(domain: "Linear", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "Linear", code: 0)
    }
    if let errors = json["errors"] as? [[String: Any]], let msg = errors.first?["message"] as? String {
        throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    return json["data"] as? [String: Any] ?? [:]
}
