import Foundation

func showIssuesOverlay(
    overlay: OverlayManager,
    tracker: TrackerService,
    session: ClaudeSession,
    statusBar: StatusBarState,
    config: Config,
    onTrackerRefresh: @escaping () -> Void,
    onUpdate: @escaping () -> Void
) {
    guard tracker.enabled else {
        overlay.show(OverlayConfig(
            title: "Issues",
            items: [
                OverlayItem(label: "No tracker configured", dimmed: true),
                OverlayItem(label: "", dimmed: true),
                OverlayItem(label: "[C] Configure Tracker", shortcut: "c", action: {
                    showTrackerSetup(overlay: overlay, config: config, onConfigured: { onTrackerRefresh(); onUpdate() }, onUpdate: onUpdate)
                }),
            ],
            onClose: onUpdate,
            footer: "[C] Configure",
            anchor: "status-issues"
        ))
        return
    }

    overlay.show(OverlayConfig(
        title: "Issues (\(tracker.type): \(tracker.teamKey))",
        items: [OverlayItem(label: "Loading issues...", dimmed: true)],
        onClose: onUpdate,
        width: 70,
        footer: "[Enter] Select  [A] Analyze  [P] Plan  [X] Fix  [N] New  [S] Status",
        anchor: "status-issues"
    ))

    loadIssues(overlay: overlay, tracker: tracker, session: session, statusBar: statusBar, config: config, onTrackerRefresh: onTrackerRefresh, onUpdate: onUpdate)
}

private func loadIssues(
    overlay: OverlayManager,
    tracker: TrackerService,
    session: ClaudeSession,
    statusBar: StatusBarState,
    config: Config,
    onTrackerRefresh: @escaping () -> Void,
    onUpdate: @escaping () -> Void
) {
    overlay.setLoading(true)
    Task {
        do {
            let issues = try await tracker.listIssues(status: nil, assignedToMe: false, limit: 20)
            await MainActor.run {
                overlay.setLoading(false)

                if issues.isEmpty {
                    overlay.updateItems([
                        OverlayItem(label: "No open issues found", dimmed: true),
                        OverlayItem(label: "", dimmed: true),
                        OverlayItem(label: "[N] Create New Issue", shortcut: "n", action: { overlay.showMessage("Use Claude to create issues (coming soon)") }),
                        OverlayItem(label: "", dimmed: true),
                        OverlayItem(label: "[C] Reconfigure Tracker", shortcut: "c", action: {
                            showTrackerSetup(overlay: overlay, config: config, onConfigured: { onTrackerRefresh(); onUpdate() }, onUpdate: onUpdate)
                        }),
                    ])
                    return
                }

                var items: [OverlayItem] = []

                if let current = statusBar.currentIssue {
                    items.append(OverlayItem(label: "Current: \(current.key) \u{2014} \(current.title)", value: current.status, dimmed: true))
                    items.append(OverlayItem(label: "", dimmed: true))
                }

                for issue in issues {
                    let isCurrent = statusBar.currentIssue?.key == issue.key
                    let icon = priorityToIcon(issue.priority)
                    let label = "\(isCurrent ? "\u{25c6}" : " ") \(issue.key)  \(icon) \(truncate(issue.title, max: 40))"
                    items.append(OverlayItem(label: label, value: issue.status, action: {
                        selectIssue(overlay: overlay, tracker: tracker, session: session, statusBar: statusBar, issue: issue, config: config, onTrackerRefresh: onTrackerRefresh, onUpdate: onUpdate)
                    }))
                }

                items.append(OverlayItem(label: "", dimmed: true))
                items.append(OverlayItem(label: "[N] Create New Issue", shortcut: "n", action: { overlay.showMessage("Use Claude to create issues (coming soon)") }))
                items.append(OverlayItem(label: "[C] Reconfigure Tracker", shortcut: "c", action: {
                    showTrackerSetup(overlay: overlay, config: config, onConfigured: { onTrackerRefresh(); onUpdate() }, onUpdate: onUpdate)
                }))

                overlay.updateItems(items)
            }
        } catch {
            await MainActor.run {
                overlay.setLoading(false)
                overlay.updateItems([
                    OverlayItem(label: "Error: \(error.localizedDescription)", dimmed: true),
                    OverlayItem(label: "", dimmed: true),
                    OverlayItem(label: "[R] Retry", shortcut: "r", action: {
                        loadIssues(overlay: overlay, tracker: tracker, session: session, statusBar: statusBar, config: config, onTrackerRefresh: onTrackerRefresh, onUpdate: onUpdate)
                    }),
                    OverlayItem(label: "[C] Reconfigure Tracker", shortcut: "c", action: {
                        showTrackerSetup(overlay: overlay, config: config, onConfigured: { onTrackerRefresh(); onUpdate() }, onUpdate: onUpdate)
                    }),
                ])
            }
        }
    }
}

private func selectIssue(
    overlay: OverlayManager,
    tracker: TrackerService,
    session: ClaudeSession,
    statusBar: StatusBarState,
    issue: Issue,
    config: Config,
    onTrackerRefresh: @escaping () -> Void,
    onUpdate: @escaping () -> Void
) {
    overlay.updateItems([
        OverlayItem(label: "\(issue.key): \(issue.title)", dimmed: true),
        OverlayItem(label: "Status: \(issue.status)  Priority: \(issue.priority)", dimmed: true),
        OverlayItem(label: "", dimmed: true),
        OverlayItem(label: "[C] Set as Current Issue", shortcut: "c", action: {
            statusBar.currentIssue = issue
            onUpdate()
            overlay.showMessage("Set current: \(issue.key)")
        }),
        OverlayItem(label: "[A] Analyze Issue", shortcut: "a", action: {
            statusBar.currentIssue = issue
            session.write("Analyze this issue and tell me what you think the problem is and what files are involved:\n\(issue.key): \(issue.title)\n")
            overlay.close()
        }),
        OverlayItem(label: "[P] Plan Implementation", shortcut: "p", action: {
            statusBar.currentIssue = issue
            session.write("Create an implementation plan for this issue. List the files to change and the approach:\n\(issue.key): \(issue.title)\n")
            overlay.close()
        }),
        OverlayItem(label: "[X] Fix Issue", shortcut: "x", action: {
            statusBar.currentIssue = issue
            session.write("Fix this issue. Analyze it, plan the fix, implement it, and test it:\n\(issue.key): \(issue.title)\n")
            overlay.close()
        }),
        OverlayItem(label: "[S] Update Status", shortcut: "s", action: {
            showStatusPicker(overlay: overlay, tracker: tracker, issue: issue, onUpdate: onUpdate)
        }),
        OverlayItem(label: "[O] Open in Browser", shortcut: "o", action: {
            NSWorkspace.shared.open(URL(string: issue.url)!)
            overlay.showMessage("Opening in browser...")
        }),
        OverlayItem(label: "", dimmed: true),
        OverlayItem(label: "[B] \u{2190} Back to List", shortcut: "b", action: {
            loadIssues(overlay: overlay, tracker: tracker, session: session, statusBar: statusBar, config: config, onTrackerRefresh: onTrackerRefresh, onUpdate: onUpdate)
        }),
    ])
}

private func showStatusPicker(
    overlay: OverlayManager,
    tracker: TrackerService,
    issue: Issue,
    onUpdate: @escaping () -> Void
) {
    let statuses = tracker.type == "linear"
        ? ["Backlog", "Todo", "In Progress", "In Review", "Done", "Canceled"]
        : ["To Do", "In Progress", "In Review", "Done"]

    overlay.updateItems(statuses.map { s in
        OverlayItem(label: "\(s == issue.status ? "\u{25c6} " : "  ")\(s)", action: {
            overlay.setLoading(true)
            Task {
                do {
                    try await tracker.updateStatus(key: issue.key, status: s)
                    await MainActor.run {
                        overlay.showMessage("Updated to \(s)")
                        onUpdate()
                        overlay.setLoading(false)
                    }
                } catch {
                    await MainActor.run {
                        overlay.showMessage("Error: \(error.localizedDescription)")
                        overlay.setLoading(false)
                    }
                }
            }
        })
    })
}

private func priorityToIcon(_ priority: String) -> String {
    let p = priority.lowercased()
    if p.contains("urgent") || p.contains("critical") { return "\u{25a0}\u{25a0}\u{25a0}" }
    if p.contains("high") { return "\u{25a0}\u{25a0}\u{25a1}" }
    if p.contains("medium") || p.contains("med") { return "\u{25a0}\u{25a1}\u{25a1}" }
    if p.contains("low") { return "\u{25a1}\u{25a1}\u{25a1}" }
    return "\u{b7}\u{b7}\u{b7}"
}

private func truncate(_ str: String, max: Int) -> String {
    str.count > max ? String(str.prefix(max - 1)) + "\u{2026}" : str
}

import AppKit
