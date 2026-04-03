import Foundation

func showHistoryOverlay(overlay: OverlayManager, history: CommandHistoryService, session: ClaudeSession, onUpdate: @escaping () -> Void) {
    let entries = history.getRecent(30).reversed()
    var items: [OverlayItem] = []

    if entries.isEmpty {
        items.append(OverlayItem(label: "No commands recorded yet", dimmed: true))
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        for entry in entries {
            let date = ISO8601DateFormatter().date(from: entry.ts) ?? Date()
            let time = formatter.string(from: date)
            items.append(OverlayItem(label: "\(time)  \(entry.cmd)", action: {
                if session.running { session.write(entry.cmd) }
                overlay.close()
            }))
        }
    }

    overlay.show(OverlayConfig(
        title: "Command History",
        items: items,
        onClose: onUpdate,
        footer: "Enter to type command into terminal",
        anchor: "status-command"
    ))
}
