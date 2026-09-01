import Foundation

/// Picker for the coding-agent CLI: Claude Code, Codex CLI, or an LM Studio
/// model (run through Codex's local provider). Choosing a different agent
/// restarts the session fresh with it; choosing "Change Claude model" injects
/// /model into the running Claude session.
func showAgentOverlay(
    overlay: OverlayManager,
    current: Agent,
    currentModel: String?,
    onChooseClaudeModel: @escaping () -> Void,
    onSwitch: @escaping (Agent, String?) -> Void,
    onUpdate: @escaping () -> Void
) {
    var items: [OverlayItem] = []

    func marker(_ active: Bool) -> String { active ? "\u{25CF} " : "  " }

    // Claude Code
    let claudeActive = current == .claude
    items.append(OverlayItem(label: "\(marker(claudeActive))[C] Claude Code", shortcut: "c", action: {
        onSwitch(.claude, nil)
    }))
    if claudeActive {
        items.append(OverlayItem(label: "    [M] Change Claude model (/model)", shortcut: "m", action: {
            onChooseClaudeModel()
        }))
    }

    // Codex CLI (ChatGPT)
    let codexActive = current == .codex
    items.append(OverlayItem(label: "\(marker(codexActive))[X] Codex CLI", shortcut: "x", action: {
        onSwitch(.codex, nil)
    }))

    // LM Studio models
    items.append(OverlayItem(label: "", dimmed: true))
    items.append(OverlayItem(label: "LM Studio models:", dimmed: true))
    let models = LMStudioModel.list()
    if models.isEmpty {
        items.append(OverlayItem(label: "  (none found — open LM Studio and download a model)", dimmed: true))
    } else {
        for m in models {
            let active = current == .lmstudio && currentModel == m.key
            items.append(OverlayItem(label: "\(marker(active))\(m.displayName)", action: {
                onSwitch(.lmstudio, m.key)
            }))
        }
    }

    overlay.show(OverlayConfig(
        title: "Agent",
        items: items,
        onClose: onUpdate,
        width: 52,
        footer: "[C] Claude  [X] Codex  \u{2022} pick an LM Studio model to run locally",
        anchor: "status-model"
    ))
}
