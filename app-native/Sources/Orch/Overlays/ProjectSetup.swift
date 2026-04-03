import Foundation

func showProjectSetup(overlay: OverlayManager, config: Config, onConfigured: @escaping () -> Void, onUpdate: @escaping () -> Void) {
    var projectId = config.projectId
    var titlePrefix = config.trackerTitlePrefix

    stepProjectId()

    func stepProjectId() {
        overlay.show(OverlayConfig(
            title: "Setup \u{2014} Step 1/4: Project ID",
            items: [
                OverlayItem(label: "Project ID is used for Clockify entries and display.", dimmed: true),
                OverlayItem(label: "", dimmed: true),
                OverlayItem(label: "Project ID:", editable: true, editValue: projectId, placeholder: config.projectName, onEdit: { projectId = $0 }),
                OverlayItem(label: "", dimmed: true),
                OverlayItem(label: "\u{2713} Accept \"\(projectId)\" and continue", action: { stepTitlePrefix() }),
                OverlayItem(label: "Use folder name: \(config.projectName)", action: {
                    projectId = config.projectName
                    stepTitlePrefix()
                }),
                OverlayItem(label: "", dimmed: true),
                OverlayItem(label: "[Enter] on the field to edit, then type. [Enter] again to stop editing.", dimmed: true),
            ],
            onClose: onUpdate,
            width: 65,
            footer: "Step 1 of 4"
        ))
    }

    func stepTitlePrefix() {
        overlay.updateItems([
            OverlayItem(label: "Prefix added to issue titles created by the orchestrator.", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "Title Prefix:", editable: true, editValue: titlePrefix, placeholder: "[AI]", onEdit: { titlePrefix = $0 }),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "\u{2713} Accept \"\(titlePrefix)\" and continue", action: { stepClockify() }),
            OverlayItem(label: "Use default: [AI]", action: { titlePrefix = "[AI]"; stepClockify() }),
            OverlayItem(label: "Skip (no prefix)", action: { titlePrefix = ""; stepClockify() }),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "\u{2190} Back", shortcut: "b", action: { stepProjectId() }),
        ])
        overlay.title = "Setup \u{2014} Step 2/4: Title Prefix"
        overlay.footer = "Step 2 of 4"
    }

    func stepClockify() {
        let hasKey = ProcessInfo.processInfo.environment["CLOCKIFY_API_KEY"] != nil
        var items: [OverlayItem] = [
            OverlayItem(label: "Clockify tracks time spent on this project.", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "CLOCKIFY_API_KEY: \(hasKey ? "\u{2713} Found in environment" : "\u{2717} Not set")", dimmed: true),
        ]

        if hasKey {
            items.append(OverlayItem(label: "", dimmed: true))
            items.append(OverlayItem(label: "\u{2713} Clockify is ready \u{2014} continue to tracker setup", action: { stepTracker() }))
        } else {
            items += [
                OverlayItem(label: "", dimmed: true),
                OverlayItem(label: "To enable Clockify time tracking:", dimmed: true),
                OverlayItem(label: "  1. Get API key from clockify.me/user/settings", dimmed: true),
                OverlayItem(label: "  2. Add CLOCKIFY_API_KEY=xxx to .env", dimmed: true),
                OverlayItem(label: "  3. Restart orch", dimmed: true),
                OverlayItem(label: "", dimmed: true),
                OverlayItem(label: "Skip Clockify for now \u{2014} continue", action: { stepTracker() }),
            ]
        }

        items.append(OverlayItem(label: "", dimmed: true))
        items.append(OverlayItem(label: "\u{2190} Back", shortcut: "b", action: { stepTitlePrefix() }))

        overlay.updateItems(items)
        overlay.title = "Setup \u{2014} Step 3/4: Clockify"
        overlay.footer = "Step 3 of 4"
    }

    func stepTracker() {
        config.save(updates: ProjectJson(
            project_id: projectId,
            tracker: TrackerConfig(type: config.trackerType, title_prefix: titlePrefix.isEmpty ? nil : titlePrefix)
        ))

        showTrackerSetup(overlay: overlay, config: config, onConfigured: {
            onConfigured()
            showSummary()
        }, onUpdate: {
            onConfigured()
            onUpdate()
        })

        overlay.title = "Setup \u{2014} Step 4/4: Issue Tracker"
        overlay.footer = "Step 4 of 4"
    }

    func showSummary() {
        config.reload()

        var items: [OverlayItem] = [
            OverlayItem(label: "\u{2713} Project configured!", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "Project ID:    \(config.projectId)", dimmed: true),
            OverlayItem(label: "Title Prefix:  \(config.trackerTitlePrefix.isEmpty ? "(none)" : config.trackerTitlePrefix)", dimmed: true),
            OverlayItem(label: "Clockify:      \(config.clockifyApiKey != nil ? "Enabled" : "Not configured")", dimmed: true),
            OverlayItem(label: "Tracker:       \(config.trackerType)", dimmed: true),
        ]

        if config.trackerType == "linear", let linear = config.linearConfig {
            items.append(OverlayItem(label: "  Team:        \(linear.team_key ?? "")", dimmed: true))
            if let proj = linear.project_name {
                items.append(OverlayItem(label: "  Project:     \(proj)", dimmed: true))
            }
        } else if config.trackerType == "jira", let jira = config.jiraConfig {
            items.append(OverlayItem(label: "  Project:     \(jira.project_key ?? "")", dimmed: true))
        }

        items += [
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "Saved to: .orch/project.json", dimmed: true),
            OverlayItem(label: "", dimmed: true),
            OverlayItem(label: "Press Esc to close.", dimmed: true),
        ]

        overlay.show(OverlayConfig(
            title: "Setup Complete",
            items: items,
            onClose: onUpdate,
            width: 60
        ))
    }
}
