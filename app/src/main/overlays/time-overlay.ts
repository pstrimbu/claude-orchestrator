import type { OverlayManager, OverlayItem } from '../overlay-manager';
import type { ClockifyService } from '../services/clockify';

export function showTimeOverlay(overlay: OverlayManager, clockify: ClockifyService, onUpdate: () => void): void {
  const buildItems = (): OverlayItem[] => {
    const items: OverlayItem[] = [];

    // Status
    items.push({
      label: `Status: ${clockify.recording ? '\u25cf Recording' : '\u25cb Stopped'}`,
      value: clockify.formatElapsed(),
      dimmed: true,
    });

    items.push({ label: '', dimmed: true });

    // Toggle recording
    items.push({
      label: clockify.recording ? '[S] Stop Recording' : '[S] Start Recording',
      shortcut: 's',
      action: () => {
        if (clockify.recording) {
          clockify.stop();
        } else {
          clockify.start();
        }
        overlay.updateItems(buildItems());
        onUpdate();
      },
    });

    // Flush now
    items.push({
      label: '[F] Flush to Clockify',
      shortcut: 'f',
      action: async () => {
        overlay.setLoading(true);
        const result = await clockify.flush();
        overlay.setLoading(false);
        if (result.success) {
          overlay.showMessage(`Flushed! Entry: ${result.entryId}`);
        } else {
          overlay.showMessage(`Failed: ${result.error}`);
        }
        overlay.updateItems(buildItems());
        onUpdate();
      },
    });

    items.push({ label: '', dimmed: true });

    // Config status
    items.push({
      label: `Clockify: ${clockify.enabled ? 'Configured' : 'Not configured'}`,
      dimmed: true,
    });

    if (!clockify.enabled) {
      items.push({
        label: 'Set CLOCKIFY_API_KEY in .env to enable',
        dimmed: true,
      });
    }

    items.push({ label: '', dimmed: true });

    // Recent entries header
    items.push({
      label: '[R] Load Recent Entries',
      shortcut: 'r',
      action: async () => {
        overlay.setLoading(true);
        const entries = await clockify.getRecentEntries(5);
        overlay.setLoading(false);
        if (entries.length === 0) {
          overlay.showMessage('No recent entries');
          return;
        }
        const newItems = buildItems();
        // Replace the "Load Recent" item with actual entries
        const idx = newItems.findIndex((i) => i.label.includes('Recent Entries'));
        if (idx >= 0) {
          newItems.splice(idx, 1,
            { label: 'Recent Entries:', dimmed: true },
            ...entries.map((e) => ({
              label: `  ${e.description || '(no description)'}`,
              value: e.timeInterval.duration || '',
              dimmed: true,
            })),
          );
        }
        overlay.updateItems(newItems);
      },
    });

    return items;
  };

  overlay.show({
    title: 'Time Tracking',
    items: buildItems(),
    onClose: onUpdate,
    footer: '[S] Start/Stop  [F] Flush  [R] Recent',
  });
}
