import type { OverlayManager } from '../overlay.js';
import type { ClockifyService } from '../services/clockify.js';
import type { TrackerService } from '../services/tracker.js';
import type { ClaudeSession } from '../claude-session.js';
import type { StatusBar } from '../status-bar.js';
import type { Config } from '../config.js';
import { showTimeOverlay } from './time-overlay.js';
import { showIssuesOverlay } from './issues-overlay.js';
import { showProjectOverlay } from './project-overlay.js';
import { showGitOverlay } from './git-overlay.js';

export function showMainMenu(
  overlay: OverlayManager,
  config: Config,
  clockify: ClockifyService,
  tracker: TrackerService,
  session: ClaudeSession,
  statusBar: StatusBar,
  refreshTracker: () => void,
  onUpdate: () => void,
): void {
  const elapsed = clockify.formatElapsed();
  const recording = clockify.recording;
  const timeStatus = recording ? `${elapsed} \u25cf recording` : `${elapsed} \u25cb stopped`;

  const trackerLabel = tracker.enabled
    ? (statusBar.currentIssue ? `${statusBar.currentIssue.key} — ${statusBar.currentIssue.title}` : tracker.teamKey || 'Issues')
    : 'Not configured';

  const gitLabel = statusBar.gitBranch
    ? `${statusBar.gitBranch}${statusBar.gitDirty ? '*' : ''}`
    : 'Not a git repo';

  overlay.show({
    title: `orch3 — ${config.projectName}`,
    items: [
      {
        label: '[P] Project',
        value: config.projectName,
        shortcut: 'p',
        action: () => {
          showProjectOverlay(overlay, config, statusBar, refreshTracker, onUpdate);
        },
      },
      {
        label: '[T] Time Tracking',
        value: timeStatus,
        shortcut: 't',
        action: () => {
          showTimeOverlay(overlay, clockify, onUpdate);
        },
      },
      {
        label: '[I] Issues',
        value: trackerLabel,
        shortcut: 'i',
        action: () => {
          showIssuesOverlay(overlay, tracker, session, statusBar, config, refreshTracker, onUpdate);
        },
      },
      {
        label: '[G] Git',
        value: gitLabel,
        shortcut: 'g',
        action: () => {
          showGitOverlay(overlay, config, session, onUpdate);
        },
      },
    ],
    onClose: onUpdate,
    footer: 'F13 to open this menu',
  });
}
