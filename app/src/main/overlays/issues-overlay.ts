import type { OverlayManager, OverlayItem } from '../overlay-manager';
import type { TrackerService, Issue } from '../services/tracker';
import type { ClaudeSession } from '../claude-session';
import type { StatusBarState } from '../status-bar-state';
import type { Config } from '../config';
import { showTrackerSetup } from './tracker-setup';

export function showIssuesOverlay(
  overlay: OverlayManager,
  tracker: TrackerService,
  session: ClaudeSession,
  statusBar: StatusBarState,
  config: Config,
  onTrackerRefresh: () => void,
  onUpdate: () => void,
): void {
  if (!tracker.enabled) {
    overlay.show({
      title: 'Issues',
      items: [
        { label: 'No tracker configured', dimmed: true },
        { label: '', dimmed: true },
        {
          label: '[C] Configure Tracker',
          shortcut: 'c',
          action: () => showTrackerSetup(overlay, config, () => {
            onTrackerRefresh();
            onUpdate();
          }, onUpdate),
        },
      ],
      onClose: onUpdate,
      footer: '[C] Configure',
    });
    return;
  }

  // Show loading state immediately
  overlay.show({
    title: `Issues (${tracker.type}: ${tracker.teamKey})`,
    items: [{ label: 'Loading issues...', dimmed: true }],
    onClose: onUpdate,
    width: 70,
    footer: '[Enter] Select  [A] Analyze  [P] Plan  [X] Fix  [N] New  [S] Status',
  });

  // Fetch issues
  loadIssues(overlay, tracker, session, statusBar, config, onTrackerRefresh, onUpdate);
}

async function loadIssues(
  overlay: OverlayManager,
  tracker: TrackerService,
  session: ClaudeSession,
  statusBar: StatusBarState,
  config: Config,
  onTrackerRefresh: () => void,
  onUpdate: () => void,
): Promise<void> {
  try {
    overlay.setLoading(true);
    const issues = await tracker.listIssues({ limit: 20 });
    overlay.setLoading(false);

    if (issues.length === 0) {
      overlay.updateItems([
        { label: 'No open issues found', dimmed: true },
        { label: '', dimmed: true },
        { label: '[N] Create New Issue', shortcut: 'n', action: () => promptNewIssue(overlay, tracker, onUpdate) },
        { label: '', dimmed: true },
        {
          label: '[C] Reconfigure Tracker',
          shortcut: 'c',
          action: () => showTrackerSetup(overlay, config, () => { onTrackerRefresh(); onUpdate(); }, onUpdate),
        },
      ]);
      return;
    }

    const items: OverlayItem[] = [];

    // Current issue indicator
    if (statusBar.currentIssue) {
      items.push({
        label: `Current: ${statusBar.currentIssue.key} \u2014 ${statusBar.currentIssue.title}`,
        value: statusBar.currentIssue.status,
        dimmed: true,
      });
      items.push({ label: '', dimmed: true });
    }

    // Issue list
    for (const issue of issues) {
      const isCurrent = statusBar.currentIssue?.key === issue.key;
      const priorityIcon = priorityToIcon(issue.priority);
      items.push({
        label: `${isCurrent ? '\u25c6' : ' '} ${issue.key}  ${priorityIcon} ${truncate(issue.title, 40)}`,
        value: issue.status,
        action: () => selectIssue(overlay, tracker, session, statusBar, issue, config, onTrackerRefresh, onUpdate),
      });
    }

    items.push({ label: '', dimmed: true });
    items.push({
      label: '[N] Create New Issue',
      shortcut: 'n',
      action: () => promptNewIssue(overlay, tracker, onUpdate),
    });
    items.push({
      label: '[C] Reconfigure Tracker',
      shortcut: 'c',
      action: () => showTrackerSetup(overlay, config, () => { onTrackerRefresh(); onUpdate(); }, onUpdate),
    });

    overlay.updateItems(items);
  } catch (err: any) {
    overlay.setLoading(false);
    overlay.updateItems([
      { label: `Error: ${err.message}`, dimmed: true },
      { label: '', dimmed: true },
      { label: '[R] Retry', shortcut: 'r', action: () => loadIssues(overlay, tracker, session, statusBar, config, onTrackerRefresh, onUpdate) },
      {
        label: '[C] Reconfigure Tracker',
        shortcut: 'c',
        action: () => showTrackerSetup(overlay, config, () => { onTrackerRefresh(); onUpdate(); }, onUpdate),
      },
    ]);
  }
}

function selectIssue(
  overlay: OverlayManager,
  tracker: TrackerService,
  session: ClaudeSession,
  statusBar: StatusBarState,
  issue: Issue,
  config: Config,
  onTrackerRefresh: () => void,
  onUpdate: () => void,
): void {
  // Show issue action submenu
  overlay.updateItems([
    { label: `${issue.key}: ${issue.title}`, dimmed: true },
    { label: `Status: ${issue.status}  Priority: ${issue.priority}`, dimmed: true },
    { label: '', dimmed: true },
    {
      label: '[C] Set as Current Issue',
      shortcut: 'c',
      action: () => {
        statusBar.currentIssue = issue;
        onUpdate();
        overlay.showMessage(`Set current: ${issue.key}`);
      },
    },
    {
      label: '[A] Analyze Issue',
      shortcut: 'a',
      action: () => {
        statusBar.currentIssue = issue;
        session.write(`Analyze this issue and tell me what you think the problem is and what files are involved:\n${issue.key}: ${issue.title}\n`);
        overlay.close();
      },
    },
    {
      label: '[P] Plan Implementation',
      shortcut: 'p',
      action: () => {
        statusBar.currentIssue = issue;
        session.write(`Create an implementation plan for this issue. List the files to change and the approach:\n${issue.key}: ${issue.title}\n`);
        overlay.close();
      },
    },
    {
      label: '[X] Fix Issue',
      shortcut: 'x',
      action: () => {
        statusBar.currentIssue = issue;
        session.write(`Fix this issue. Analyze it, plan the fix, implement it, and test it:\n${issue.key}: ${issue.title}\n`);
        overlay.close();
      },
    },
    {
      label: '[S] Update Status',
      shortcut: 's',
      action: () => showStatusPicker(overlay, tracker, issue, onUpdate),
    },
    {
      label: '[O] Open in Browser',
      shortcut: 'o',
      action: () => {
        import('child_process').then(({ exec }) => exec(`open "${issue.url}"`));
        overlay.showMessage('Opening in browser...');
      },
    },
    { label: '', dimmed: true },
    {
      label: '[B] \u2190 Back to List',
      shortcut: 'b',
      action: () => loadIssues(overlay, tracker, session, statusBar, config, onTrackerRefresh, onUpdate),
    },
  ]);
}

function showStatusPicker(
  overlay: OverlayManager,
  tracker: TrackerService,
  issue: Issue,
  onUpdate: () => void,
): void {
  const statuses = tracker.type === 'linear'
    ? ['Backlog', 'Todo', 'In Progress', 'In Review', 'Done', 'Canceled']
    : ['To Do', 'In Progress', 'In Review', 'Done'];

  overlay.updateItems(
    statuses.map((s) => ({
      label: `${s === issue.status ? '\u25c6 ' : '  '}${s}`,
      action: async () => {
        overlay.setLoading(true);
        try {
          await tracker.updateStatus(issue.key, s);
          issue.status = s;
          overlay.showMessage(`Updated to ${s}`);
          onUpdate();
        } catch (err: any) {
          overlay.showMessage(`Error: ${err.message}`);
        }
        overlay.setLoading(false);
      },
    })),
  );
}

function promptNewIssue(
  _overlay: OverlayManager,
  _tracker: TrackerService,
  _onUpdate: () => void,
): void {
  _overlay.showMessage('Use Claude to create issues (coming soon)');
}

function priorityToIcon(priority: string): string {
  const p = priority.toLowerCase();
  if (p.includes('urgent') || p.includes('critical')) return '\u25a0\u25a0\u25a0';
  if (p.includes('high')) return '\u25a0\u25a0\u25a1';
  if (p.includes('medium') || p.includes('med')) return '\u25a0\u25a1\u25a1';
  if (p.includes('low')) return '\u25a1\u25a1\u25a1';
  return '\u00b7\u00b7\u00b7';
}

function truncate(str: string, max: number): string {
  return str.length > max ? str.slice(0, max - 1) + '\u2026' : str;
}
