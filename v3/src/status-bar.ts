import type { Screen } from './screen.js';
import type { ClockifyService } from './services/clockify.js';
import type { TrackerService, Issue } from './services/tracker.js';
import type { Config } from './config.js';

export class StatusBar {
  currentIssue: Issue | null = null;
  gitBranch = '';
  gitDirty = false;

  constructor(
    private screen: Screen,
    private config: Config,
    private clockify: ClockifyService,
    private tracker: TrackerService,
  ) {}

  // Kept for compatibility — no-op since there are no clickable sections
  sectionAtCol(_col: number): number {
    return -1;
  }

  render(): void {
    const parts: string[] = [];

    // Project name
    parts.push(this.config.projectName);

    // Time tracking
    const elapsed = this.clockify.formatElapsed();
    const recording = this.clockify.recording;
    parts.push(recording ? `${elapsed} \u25cf` : `${elapsed} \u25cb`);

    // Issue tracker
    if (this.currentIssue) {
      parts.push(`${this.currentIssue.key}`);
    } else if (this.tracker.enabled) {
      parts.push(this.tracker.teamKey || 'Issues');
    }

    // Git
    if (this.gitBranch) {
      parts.push(`${this.gitBranch}${this.gitDirty ? '*' : ''}`);
    }

    this.screen.setTitle(parts.join(' \u2502 '));
  }

  focusNext(): void {}
  focusPrev(): void {}
  focusSection(_idx: number): void {}
  unfocus(): void {}
}
