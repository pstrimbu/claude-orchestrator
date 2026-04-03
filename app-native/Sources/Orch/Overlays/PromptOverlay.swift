import Foundation

private let reviewSystem = """
You are a prompt engineering reviewer. Analyze prompts against this optimal structure:

1. SYSTEM — Role + behavior constraints (who the AI should be)
2. CONTEXT — Facts/state the AI needs (what is true right now)
3. TASK — Clear, specific objective (what to do)
4. REQUIREMENTS — Constraints on the answer (what must be true about the output)
5. OUTPUT — Format specification (how to structure the response)

Respond with ONLY valid JSON, no markdown fencing:
{
  "sections": [
    {"name": "SYSTEM", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "CONTEXT", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "TASK", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "REQUIREMENTS", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "OUTPUT", "status": "present|weak|missing", "note": "brief explanation"}
  ],
  "enhanced": "the improved prompt"
}
"""

struct PromptReview: Codable {
    struct Section: Codable {
        let name: String
        let status: String
        let note: String
    }
    let sections: [Section]
    let enhanced: String
}

func showPromptBuilderOverlay(overlay: OverlayManager, config: Config, session: ClaudeSession) {
    var promptText = ""
    var review: PromptReview?

    func statusIcon(_ s: String) -> String {
        if s == "present" { return "\u{2713}" }
        if s == "weak" { return "~" }
        return "\u{2717}"
    }

    func buildItems() -> [OverlayItem] {
        var items: [OverlayItem] = []

        items.append(OverlayItem(
            label: "Prompt:",
            editable: true,
            editValue: promptText,
            placeholder: "Type your prompt here...",
            onEdit: { promptText = $0 },
            onSubmit: { value in
                guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                guard let apiKey = config.anthropicApiKey else {
                    overlay.showMessage("Set ANTHROPIC_API_KEY in .env to enable review")
                    return
                }
                overlay.setLoading(true)
                Task {
                    do {
                        let r = try await reviewPrompt(apiKey: apiKey, promptText: value)
                        await MainActor.run {
                            review = r
                            promptText = value
                            overlay.updateItems(buildItems())
                            overlay.setLoading(false)
                        }
                    } catch {
                        await MainActor.run {
                            overlay.showMessage("Review failed: \(error.localizedDescription)")
                            overlay.setLoading(false)
                        }
                    }
                }
            }
        ))

        items.append(OverlayItem(label: "", dimmed: true))

        if let r = review {
            for sec in r.sections {
                items.append(OverlayItem(label: "  \(statusIcon(sec.status)) \(sec.name): \(sec.note)", dimmed: true))
            }
            items.append(OverlayItem(label: "", dimmed: true))

            items.append(OverlayItem(label: "[A] Apply enhanced prompt", shortcut: "a", action: {
                if let r = review {
                    promptText = r.enhanced
                    review = nil
                    overlay.updateItems(buildItems())
                    overlay.showMessage("Enhanced prompt applied")
                }
            }))
        }

        items.append(OverlayItem(label: "[R] Review prompt structure", shortcut: "r", action: {
            guard !promptText.trimmingCharacters(in: .whitespaces).isEmpty else {
                overlay.showMessage("Type a prompt first")
                return
            }
            guard let apiKey = config.anthropicApiKey else {
                overlay.showMessage("Set ANTHROPIC_API_KEY in .env")
                return
            }
            overlay.setLoading(true)
            Task {
                do {
                    let r = try await reviewPrompt(apiKey: apiKey, promptText: promptText)
                    await MainActor.run {
                        review = r
                        overlay.updateItems(buildItems())
                        overlay.setLoading(false)
                    }
                } catch {
                    await MainActor.run {
                        overlay.showMessage("Error: \(error.localizedDescription)")
                        overlay.setLoading(false)
                    }
                }
            }
        }))

        items.append(OverlayItem(label: "[S] Send to Claude", shortcut: "s", action: {
            if !promptText.trimmingCharacters(in: .whitespaces).isEmpty, session.running {
                session.write(promptText + "\n")
            }
            overlay.close()
        }))

        return items
    }

    overlay.show(OverlayConfig(
        title: "Prompt Builder",
        items: buildItems(),
        onClose: {},
        footer: "[Enter] Review  [A] Apply  [S] Send  [Esc] Close",
        anchor: "status-prompt"
    ))
}

private func reviewPrompt(apiKey: String, promptText: String) async throws -> PromptReview {
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")

    let body: [String: Any] = [
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 1500,
        "system": reviewSystem,
        "messages": [["role": "user", "content": "Review this prompt:\n\n\(promptText)"]],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(domain: "API", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = (json["content"] as? [[String: Any]])?.first,
          let text = content["text"] as? String else {
        throw NSError(domain: "API", code: 0, userInfo: [NSLocalizedDescriptionKey: "Empty response"])
    }

    let cleaned = text
        .replacingOccurrences(of: "^```(?:json)?\\s*\\n?", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\n?```\\s*$", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return try JSONDecoder().decode(PromptReview.self, from: cleaned.data(using: .utf8)!)
}
