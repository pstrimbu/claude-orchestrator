import type { OverlayManager, OverlayItem } from '../overlay-manager';
import type { Config } from '../config';
import type { ClaudeSession } from '../claude-session';

interface PromptReview {
  sections: { name: string; status: 'present' | 'weak' | 'missing'; note: string }[];
  enhanced: string;
}

const REVIEW_SYSTEM = `You are a prompt engineering reviewer. Analyze prompts against this optimal structure:

1. SYSTEM — Role + behavior constraints (who the AI should be)
2. CONTEXT — Facts/state the AI needs (what is true right now)
3. TASK — Clear, specific objective (what to do)
4. REQUIREMENTS — Constraints on the answer (what must be true about the output)
5. OUTPUT — Format specification (how to structure the response)

Claude performs best when you remove ambiguity about: who it is, what it knows, what you want, and how it should respond.

Common failures: missing context (AI guesses), vague requirements (AI rambles), no output format (AI generalizes).

Respond with ONLY valid JSON, no markdown fencing:
{
  "sections": [
    {"name": "SYSTEM", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "CONTEXT", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "TASK", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "REQUIREMENTS", "status": "present|weak|missing", "note": "brief explanation"},
    {"name": "OUTPUT", "status": "present|weak|missing", "note": "brief explanation"}
  ],
  "enhanced": "the improved prompt with proper structure using SYSTEM:/CONTEXT:/TASK:/REQUIREMENTS:/OUTPUT: headers"
}`;

async function reviewPrompt(apiKey: string, promptText: string): Promise<PromptReview> {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 1500,
      system: REVIEW_SYSTEM,
      messages: [{
        role: 'user',
        content: `Review this prompt:\n\n${promptText}`,
      }],
    }),
  });

  if (!res.ok) {
    throw new Error(`API error: ${res.status}`);
  }

  const data = await res.json() as any;
  const text = data?.content?.[0]?.text?.trim();
  if (!text) throw new Error('Empty response');

  // Strip markdown fencing if present
  const cleaned = text.replace(/^```(?:json)?\s*\n?/i, '').replace(/\n?```\s*$/i, '').trim();
  return JSON.parse(cleaned) as PromptReview;
}

export function showPromptBuilderOverlay(
  overlay: OverlayManager,
  config: Config,
  session: ClaudeSession,
): void {
  let promptText = '';
  let review: PromptReview | null = null;

  const statusIcon = (s: string): string => {
    if (s === 'present') return '\u2713';
    if (s === 'weak') return '~';
    return '\u2717';
  };

  const buildItems = (): OverlayItem[] => {
    const items: OverlayItem[] = [];

    items.push({
      label: 'Prompt:',
      editable: true,
      editValue: promptText,
      placeholder: 'Type your prompt here...',
      onEdit: (value: string) => { promptText = value; },
      onSubmit: async (value: string) => {
        if (!value.trim()) return;
        const apiKey = config.anthropicApiKey;
        if (!apiKey) {
          overlay.showMessage('Set ANTHROPIC_API_KEY in .env to enable review');
          return;
        }
        overlay.setLoading(true);
        try {
          review = await reviewPrompt(apiKey, value);
          promptText = value;
          overlay.updateItems(buildItems());
        } catch (err: any) {
          overlay.showMessage('Review failed: ' + err.message);
        }
        overlay.setLoading(false);
      },
    });

    items.push({ label: '', dimmed: true });

    // Show review results if available
    if (review) {
      for (const sec of review.sections) {
        const icon = statusIcon(sec.status);
        items.push({
          label: `  ${icon} ${sec.name}: ${sec.note}`,
          dimmed: true,
        });
      }
      items.push({ label: '', dimmed: true });

      items.push({
        label: '[A] Apply enhanced prompt',
        shortcut: 'a',
        action: () => {
          if (review?.enhanced) {
            promptText = review.enhanced;
            review = null;
            overlay.updateItems(buildItems());
            overlay.showMessage('Enhanced prompt applied');
          }
        },
      });
    }

    items.push({
      label: '[R] Review prompt structure',
      shortcut: 'r',
      action: async () => {
        if (!promptText.trim()) {
          overlay.showMessage('Type a prompt first');
          return;
        }
        const apiKey = config.anthropicApiKey;
        if (!apiKey) {
          overlay.showMessage('Set ANTHROPIC_API_KEY in .env');
          return;
        }
        overlay.setLoading(true);
        try {
          review = await reviewPrompt(apiKey, promptText);
          overlay.updateItems(buildItems());
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
    footer: '[Enter] Review  [A] Apply  [S] Send  [Esc] Close',
  });
}
