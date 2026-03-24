import type { OverlayManager, OverlayItem } from '../overlay-manager';
import type { CommandHistoryService } from '../services/command-history';
import type { ClaudeSession } from '../claude-session';

export function showHistoryOverlay(
  overlay: OverlayManager,
  history: CommandHistoryService,
  session: ClaudeSession,
  onUpdate: () => void,
): void {
  const entries = history.getRecent(30).reverse(); // newest first

  const items: OverlayItem[] = [];

  if (entries.length === 0) {
    items.push({ label: 'No commands recorded yet', dimmed: true });
  } else {
    for (const entry of entries) {
      const time = new Date(entry.ts);
      const hh = time.getHours().toString().padStart(2, '0');
      const mm = time.getMinutes().toString().padStart(2, '0');
      const cmd = entry.cmd;

      items.push({
        label: `${hh}:${mm}  ${cmd}`,
        action: () => {
          // Type the command into the terminal (don't auto-submit)
          if (session?.running) {
            session.write(cmd);
          }
          overlay.close();
        },
      });
    }
  }

  overlay.show({
    title: 'Command History',
    items,
    onClose: onUpdate,
    anchor: 'status-command',
    footer: 'Enter to type command into terminal',
  });
}
