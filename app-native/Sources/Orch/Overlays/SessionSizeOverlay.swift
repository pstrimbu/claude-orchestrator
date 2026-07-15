import Foundation

/// Overlay shown when the context-size section in the status bar is clicked.
/// Displays the current session's context usage and offers quick actions to
/// consolidate (/compact), restart, or start a fresh session (/clear).
func showSessionSizeOverlay(
    overlay: OverlayManager,
    session: ClaudeSession,
    state: StatusBarState,
    onRestart: @escaping () -> Void,
    onUpdate: @escaping () -> Void
) {
    var items: [OverlayItem] = []

    let tokens = state.contextTokens
    let limit = state.contextLimit
    // Prefer Claude's own used_percentage so this agrees with `/context` and
    // with the status bar; fall back to dividing only if it hasn't reported one.
    let pct = state.contextFraction > 0
        ? Int((state.contextFraction * 100).rounded())
        : (limit > 0 ? Int((Double(tokens) / Double(limit) * 100).rounded()) : 0)

    func fmt(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.2fM", Double(n) / 1_000_000)
        }
        let k = Int((Double(n) / 1000).rounded())
        return "\(k)k"
    }

    if tokens > 0 {
        items.append(OverlayItem(label: "Context: \(fmt(tokens)) / \(fmt(limit))  (\(pct)%)", dimmed: true))
        if let m = state.contextModel { items.append(OverlayItem(label: "Model: \(m)", dimmed: true)) }
        let health = pct >= 85 ? "\u{25cf} full — consolidate or restart"
                   : pct >= 60 ? "\u{25cf} getting full"
                               : "\u{25cf} healthy"
        items.append(OverlayItem(label: health, dimmed: true))
    } else {
        items.append(OverlayItem(label: "Context size not available yet", dimmed: true))
    }
    items.append(OverlayItem(label: "", dimmed: true))

    // Consolidate — summarize the conversation to reclaim context, keep working.
    items.append(OverlayItem(label: "Consolidate  (/compact)", action: {
        session.write("/compact\n")
        overlay.close()
    }))

    // Restart — kill and relaunch the session in place with --continue (same
    // history reloaded; clears transient state). Uses the existing Ctrl+R path.
    items.append(OverlayItem(label: "Restart session  (Ctrl+R)", action: {
        onRestart()
        overlay.close()
    }))

    // New — drop the current context entirely and start fresh.
    items.append(OverlayItem(label: "New session  (/clear)", action: {
        session.write("/clear\n")
        overlay.close()
    }))

    overlay.show(OverlayConfig(
        title: "Session Size",
        items: items,
        onClose: onUpdate,
        footer: "[Enter] Select  [Esc] Close",
        anchor: "status-size"
    ))
}
