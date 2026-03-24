import type { OverlayManager, OverlayItem } from '../overlay-manager';
import type { Config } from '../config';
import type { ClaudeSession } from '../claude-session';

export function showPromptBuilderOverlay(
  overlay: OverlayManager,
  config: Config,
  session: ClaudeSession,
): void {
  let promptText = '';

  const buildItems = (): OverlayItem[] => {
    const items: OverlayItem[] = [];

    items.push({
      label: 'Prompt:',
      editable: true,
      editValue: promptText,
      placeholder: 'Type your prompt here...',
      onEdit: (value: string) => { promptText = value; },
    });

    items.push({ label: '', dimmed: true });

    items.push({
      label: '[E] Enhance with AI',
      shortcut: 'e',
      action: async () => {
        if (!promptText.trim()) {
          overlay.showMessage('Type a prompt first');
          return;
        }
        const apiKey = config.anthropicApiKey;
        if (!apiKey) {
          overlay.showMessage('Set ANTHROPIC_API_KEY in .env to use Enhance');
          return;
        }
        overlay.setLoading(true);
        try {
          const res = await fetch('https://api.anthropic.com/v1/messages', {
            method: 'POST',
            headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
            },
            body: JSON.stringify({
              model: 'claude-haiku-4-5-20251001',
              max_tokens: 500,
              messages: [{
                role: 'user',
                content: `Improve this prompt to be clearer and more effective for a coding AI assistant. Return only the improved prompt, nothing else.\n\nOriginal prompt:\n${promptText}`,
              }],
            }),
          });
          if (res.ok) {
            const data = await res.json() as any;
            const enhanced = data?.content?.[0]?.text?.trim();
            if (enhanced) {
              promptText = enhanced;
              overlay.updateItems(buildItems());
              overlay.showMessage('Prompt enhanced');
            }
          } else {
            overlay.showMessage('API error: ' + res.status);
          }
        } catch (err: any) {
          overlay.showMessage('Error: ' + err.message);
        }
        overlay.setLoading(false);
      },
    });

    items.push({
      label: '[S] Send to Claude',
      shortcut: 's',
      action: () => {
        if (promptText.trim() && session?.running) {
          session.write(promptText + '\n');
        }
        overlay.close();
      },
    });

    return items;
  };

  overlay.show({
    title: 'Prompt Builder',
    items: buildItems(),
    anchor: 'status-prompt',
    onClose: () => {},
    footer: '[E] Enhance  [S] Send  [Esc] Close',
  });
}
