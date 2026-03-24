import type { OverlayManager } from '../overlay-manager';
import type { ClockifyService } from '../services/clockify';
import type { TrackerService } from '../services/tracker';
import type { CommandHistoryService } from '../services/command-history';
import type { ClaudeSession } from '../claude-session';
import type { StatusBarState } from '../status-bar-state';
import type { Config } from '../config';
import { showTimeOverlay } from './time-overlay';
import { showIssuesOverlay } from './issues-overlay';
import { showProjectOverlay } from './project-overlay';
import { showGitOverlay } from './git-overlay';
import { showHistoryOverlay } from './history-overlay';
import { VERSION } from '../version';

export function showMainMenu(
  overlay: OverlayManager,
  config: Config,
  clockify: ClockifyService,
  tracker: TrackerService,
  history: CommandHistoryService,
  session: ClaudeSession,
  statusBar: StatusBarState,
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
    title: `orch ${VERSION} — ${config.projectName}`,
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
      {
        label: '[H] History',
        value: `${history.getRecent(1).length > 0 ? history.getRecent(1)[0]!.cmd : 'No commands'}`,
        shortcut: 'h',
        action: () => {
          showHistoryOverlay(overlay, history, session, onUpdate);
        },
      },
    ],
    onClose: onUpdate,
    footer: 'F13 to open this menu',
  });
}
