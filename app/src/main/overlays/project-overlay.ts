import type { OverlayManager } from '../overlay-manager';
import type { Config } from '../config';
import type { StatusBarState } from '../status-bar-state';
import { execSync } from 'child_process';
import { showProjectSetup } from './project-setup';

export function showProjectOverlay(
  overlay: OverlayManager,
  config: Config,
  statusBar: StatusBarState,
  onTrackerRefresh: () => void,
  onUpdate: () => void,
): void {
  const items = [];

  // Project info
  items.push({ label: `Project: ${config.projectName}`, dimmed: true });
  items.push({ label: `Path: ${config.projectPath}`, dimmed: true });
  items.push({ label: `Project ID: ${config.projectId}`, dimmed: true });
  items.push({ label: `Tracker: ${config.trackerType}`, dimmed: true });
  items.push({ label: `Clockify: ${config.clockifyApiKey ? 'Configured' : 'Not configured'}`, dimmed: true });
  items.push({ label: '', dimmed: true });

  // Git info
  const gitOpts = { cwd: config.projectPath, encoding: 'utf-8' as const, stdio: ['pipe', 'pipe', 'pipe'] as ['pipe', 'pipe', 'pipe'] };
  try {
    const branch = execSync('git rev-parse --abbrev-ref HEAD', gitOpts).trim();
    const status = execSync('git status --short', gitOpts).trim();
    const changedFiles = status ? status.split('\n').length : 0;
    const log = execSync('git log --oneline -5', gitOpts).trim();

    items.push({ label: `Branch: ${branch}`, dimmed: true });
    items.push({ label: `Changed files: ${changedFiles}`, dimmed: true });
    items.push({ label: '', dimmed: true });

    items.push({ label: 'Recent Commits:', dimmed: true });
    for (const line of log.split('\n')) {
      items.push({ label: `  ${line}`, dimmed: true });
    }
  } catch {
    items.push({ label: 'Git: not available', dimmed: true });
  }

  items.push({ label: '', dimmed: true });

  // Actions
  items.push({
    label: '[W] Run Setup Wizard',
    shortcut: 'w',
    action: () => showProjectSetup(overlay, config, () => {
      onTrackerRefresh();
      onUpdate();
    }, onUpdate),
  });

  items.push({
    label: '[E] Open in Editor',
    shortcut: 'e',
    action: () => {
      try {
        execSync(`code "${config.projectPath}"`, { stdio: 'ignore' });
        overlay.showMessage('Opened in VS Code');
      } catch {
        overlay.showMessage('Could not open editor');
      }
    },
  });

  items.push({
    label: '[F] Open in Finder',
    shortcut: 'f',
    action: () => {
      try {
        execSync(`open "${config.projectPath}"`, { stdio: 'ignore' });
        overlay.showMessage('Opened in Finder');
      } catch {
        overlay.showMessage('Could not open Finder');
      }
    },
  });

  overlay.show({
    title: 'Project',
    items,
    onClose: onUpdate,
    anchor: 'status-project',
    width: 65,
    footer: '[W] Wizard  [E] Editor  [F] Finder',
  });
}
