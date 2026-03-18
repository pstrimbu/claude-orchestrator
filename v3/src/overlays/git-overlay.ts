import type { OverlayManager, OverlayItem } from '../overlay.js';
import type { ClaudeSession } from '../claude-session.js';
import type { Config } from '../config.js';
import { execSync } from 'child_process';

export function showGitOverlay(
  overlay: OverlayManager,
  config: Config,
  session: ClaudeSession,
  onUpdate: () => void,
): void {
  const items: OverlayItem[] = [];

  const gitOpts = { cwd: config.projectPath, encoding: 'utf-8' as const, stdio: ['pipe', 'pipe', 'pipe'] as ['pipe', 'pipe', 'pipe'] };
  try {
    const branch = execSync('git rev-parse --abbrev-ref HEAD', gitOpts).trim();
    const statusOut = execSync('git status --short', gitOpts).trim();
    const changedFiles = statusOut ? statusOut.split('\n') : [];
    const ahead = getAheadBehind(config.projectPath);

    items.push({ label: `Branch: ${branch}`, dimmed: true });
    items.push({ label: `${changedFiles.length} changed files${ahead}`, dimmed: true });
    items.push({ label: '', dimmed: true });

    // Changed files
    if (changedFiles.length > 0) {
      items.push({ label: 'Changed Files:', dimmed: true });
      for (const file of changedFiles.slice(0, 15)) {
        items.push({ label: `  ${file}`, dimmed: true });
      }
      if (changedFiles.length > 15) {
        items.push({ label: `  ... and ${changedFiles.length - 15} more`, dimmed: true });
      }
      items.push({ label: '', dimmed: true });
    }

    // Actions
    items.push({
      label: 'Ask Claude to Commit',
      action: () => {
        session.write('/commit\n');
        overlay.close();
      },
    });

    items.push({
      label: 'Ask Claude to Review Changes',
      action: () => {
        session.write('Review the current git diff and tell me if the changes look good.\n');
        overlay.close();
      },
    });

    items.push({
      label: 'Ask Claude to Create PR',
      action: () => {
        session.write('Create a pull request for the current branch.\n');
        overlay.close();
      },
    });

    items.push({ label: '', dimmed: true });

    // Quick git actions
    items.push({
      label: 'Git Stash',
      action: () => {
        try {
          execSync('git stash', { cwd: config.projectPath });
          overlay.showMessage('Stashed changes');
          onUpdate();
        } catch (e: any) {
          overlay.showMessage(`Error: ${e.message}`);
        }
      },
    });

    items.push({
      label: 'Git Stash Pop',
      action: () => {
        try {
          execSync('git stash pop', { cwd: config.projectPath });
          overlay.showMessage('Popped stash');
          onUpdate();
        } catch (e: any) {
          overlay.showMessage(`Error: ${e.message}`);
        }
      },
    });
  } catch {
    items.push({ label: 'Not a git repository', dimmed: true });
  }

  overlay.show({
    title: 'Git',
    items,
    onClose: onUpdate,
    footer: '[Enter] Select  [Esc] Close',
  });
}

function getAheadBehind(cwd: string): string {
  try {
    const out = execSync('git rev-list --left-right --count HEAD...@{upstream}', { cwd, encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
    const [ahead, behind] = out.split('\t').map(Number);
    const parts = [];
    if (ahead) parts.push(`\u2191${ahead}`);
    if (behind) parts.push(`\u2193${behind}`);
    return parts.length ? `  ${parts.join(' ')}` : '';
  } catch {
    return '';
  }
}
