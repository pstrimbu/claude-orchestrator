import Foundation

func showSessionsOverlay(
    overlay: OverlayManager,
    sessionStore: SessionStore,
    session: ClaudeSession,
    currentSessionId: String?,
    onSessionSwitch: @escaping (SessionMode) -> Void,
    onUpdate: @escaping () -> Void
) {
    let sessions = sessionStore.listSessions(limit: 9)

    var items: [OverlayItem] = []

    // Current session info
    let currentLabel = currentSessionId.map { String($0.prefix(8)) } ?? "unknown"
    items.append(OverlayItem(label: "Current: \(currentLabel)", dimmed: true))
    items.append(OverlayItem(label: "", dimmed: true))

    // Session actions
    items.append(OverlayItem(
        label: "[N] New Session",
        shortcut: "n",
        action: {
            overlay.close()
            onSessionSwitch(.new)
        }
    ))

    items.append(OverlayItem(
        label: "[R] Rename Session",
        shortcut: "r",
        editable: true,
        placeholder: "Session name",
        onSubmit: { name in
            guard !name.isEmpty else { return }
            session.write("/rename \(name)\n")
            overlay.close()
            onUpdate()
        }
    ))

    items.append(OverlayItem(label: "", dimmed: true))

    // Recent sessions (excluding current)
    let otherSessions = sessions.filter { $0.sessionId != currentSessionId }
    if !otherSessions.isEmpty {
        items.append(OverlayItem(label: "Recent:", dimmed: true))

        for (i, s) in otherSessions.prefix(9).enumerated() {
            let preview = String(s.firstMessage.prefix(40))
            let ago = formatTimeAgo(s.lastTimestamp)
            items.append(OverlayItem(
                label: "[\(i + 1)] \(preview)",
                value: "\(ago), \(s.messageCount) msgs",
                shortcut: "\(i + 1)",
                action: {
                    overlay.close()
                    onSessionSwitch(.resume(id: s.sessionId))
                }
            ))
        }

        items.append(OverlayItem(label: "", dimmed: true))
    }

    // Quick commands
    items.append(OverlayItem(label: "Commands:", dimmed: true))

    items.append(OverlayItem(
        label: "[K] /compact \u{2014} compress context",
        shortcut: "k",
        action: {
            overlay.close()
            session.write("/compact\n")
        }
    ))

    items.append(OverlayItem(
        label: "[D] /diff \u{2014} view git changes",
        shortcut: "d",
        action: {
            overlay.close()
            session.write("/diff\n")
        }
    ))

    overlay.show(OverlayConfig(
        title: "Sessions",
        items: items,
        onClose: onUpdate,
        footer: "[N] New  [R] Rename  [1-9] Switch  [K] Compact  [D] Diff",
        anchor: "sessions"
    ))
}

private func formatTimeAgo(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
}
