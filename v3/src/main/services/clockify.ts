import type { Config } from '../config';

interface TimeEntry {
  id: string;
  description: string;
  timeInterval: {
    start: string;
    end: string;
    duration: string;
  };
}

interface ClockifyProject {
  id: string;
  name: string;
}

export class ClockifyService {
  private projectId: string | null = null;
  private _recording = false;
  private _startTime: Date | null = null;
  private _accumulated = 0; // seconds
  private _flushTimer: ReturnType<typeof setInterval> | null = null;
  private _idleCheckTimer: ReturnType<typeof setInterval> | null = null;
  private _eodCheckTimer: ReturnType<typeof setInterval> | null = null;
  private _lastActivityTime = 0;
  private _lastActivityDay = -1; // day-of-year of last activity
  private _summaryProvider: (() => Promise<string>) | null = null;
  private static readonly IDLE_TIMEOUT_MS = 60_000; // pause after 60s of no output

  constructor(private config: Config) {
    // Check every 60s if the day has rolled over
    this._eodCheckTimer = setInterval(() => this.checkEndOfDay(), 60_000);
  }

  setSummaryProvider(provider: () => Promise<string>): void {
    this._summaryProvider = provider;
  }

  get enabled(): boolean {
    return !!this.config.clockifyApiKey;
  }

  get recording(): boolean {
    return this._recording;
  }

  get elapsed(): number {
    if (!this._recording || !this._startTime) return this._accumulated;
    return this._accumulated + Math.floor((Date.now() - this._startTime.getTime()) / 1000);
  }

  formatElapsed(): string {
    const total = this.elapsed;
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    if (h > 0) return `${h}h${m.toString().padStart(2, '0')}m`;
    return `${m}m`;
  }

  start(): void {
    if (this._recording) return;
    this._recording = true;
    this._startTime = new Date();

    // Auto-flush every 30 minutes
    this._flushTimer = setInterval(() => this.flush(), 30 * 60 * 1000);
  }

  stop(): void {
    if (!this._recording) return;
    // Accumulate elapsed time
    if (this._startTime) {
      this._accumulated += Math.floor((Date.now() - this._startTime.getTime()) / 1000);
    }
    this._recording = false;
    this._startTime = null;

    if (this._flushTimer) {
      clearInterval(this._flushTimer);
      this._flushTimer = null;
    }
  }

  // Track activity from PTY output — call this when Claude produces output
  onActivity(): void {
    this._lastActivityTime = Date.now();
    this._lastActivityDay = this.dayOfYear(new Date());

    if (!this.enabled) return;

    // Auto-start recording when AI produces output
    if (!this._recording) {
      this.start();
    }

    // Ensure idle check is running
    if (!this._idleCheckTimer) {
      this._idleCheckTimer = setInterval(() => this.checkIdle(), 10_000);
    }
  }

  private checkIdle(): void {
    if (!this._recording) return;
    const idle = Date.now() - this._lastActivityTime;
    if (idle >= ClockifyService.IDLE_TIMEOUT_MS) {
      // Pause — only count time up to last activity, not the idle gap
      if (this._startTime) {
        const activeEnd = this._lastActivityTime;
        const activeStart = this._startTime.getTime();
        if (activeEnd > activeStart) {
          this._accumulated += Math.floor((activeEnd - activeStart) / 1000);
        }
      }
      this._recording = false;
      this._startTime = null;
      if (this._flushTimer) {
        clearInterval(this._flushTimer);
        this._flushTimer = null;
      }
    }
  }

  private checkEndOfDay(): void {
    if (!this.enabled) return;
    if (this._lastActivityDay < 0) return; // no activity yet

    const today = this.dayOfYear(new Date());
    if (today === this._lastActivityDay) return; // same day

    // Day rolled over — flush any accumulated time ending at last activity
    const seconds = this.elapsed;
    if (seconds >= 60) {
      console.log('[clockify] end-of-day flush:', seconds, 'seconds');
      this.flush(true).catch((e) => console.error('[clockify] eod flush error:', e));
    } else if (seconds > 0) {
      // Less than a minute — just reset
      this._accumulated = 0;
      this._startTime = this._recording ? new Date() : null;
    }
    this._lastActivityDay = today;
  }

  private dayOfYear(d: Date): number {
    const start = new Date(d.getFullYear(), 0, 0);
    return Math.floor((d.getTime() - start.getTime()) / 86_400_000);
  }

  async flush(useLastActivity = false): Promise<{ success: boolean; entryId?: string; error?: string }> {
    if (!this.enabled) return { success: false, error: 'Clockify not configured' };

    const seconds = this.elapsed;
    if (seconds < 60) return { success: false, error: 'Less than 1 minute accumulated' };

    // Build summary
    let summary: string;
    if (this._summaryProvider) {
      try {
        summary = await this._summaryProvider();
      } catch {
        summary = `Active work on ${this.config.projectId}`;
      }
    } else {
      summary = `Active work on ${this.config.projectId}`;
    }

    // Calculate start/end times — end-of-day flushes end at last activity
    const end = (useLastActivity && this._lastActivityTime > 0)
      ? new Date(this._lastActivityTime)
      : new Date();
    const start = new Date(end.getTime() - seconds * 1000);

    try {
      const projectId = await this.ensureProject();
      if (!projectId) return { success: false, error: 'Could not find/create Clockify project' };

      const entry = await this.createTimeEntry(start, end, summary, projectId);

      // Reset state
      this._accumulated = 0;
      this._startTime = this._recording ? new Date() : null;

      return { success: true, entryId: entry.id };
    } catch (err: any) {
      return { success: false, error: err.message };
    }
  }

  async getRecentEntries(limit = 5): Promise<TimeEntry[]> {
    if (!this.enabled) return [];
    try {
      const projectId = await this.ensureProject();
      if (!projectId) return [];

      const data = await this.api(
        'GET',
        `/workspaces/${this.config.clockifyWorkspaceId}/user/${this.config.clockifyUserId}/time-entries?page-size=${limit}&project=${projectId}`,
      );
      return data as TimeEntry[];
    } catch {
      return [];
    }
  }

  private async ensureProject(): Promise<string | null> {
    if (this.projectId) return this.projectId;

    // Search for existing project
    const projects = (await this.api(
      'GET',
      `/workspaces/${this.config.clockifyWorkspaceId}/projects?name=${encodeURIComponent(this.config.projectId)}`,
    )) as ClockifyProject[];

    const match = projects.find((p) => p.name === this.config.projectId);
    if (match) {
      this.projectId = match.id;
      return this.projectId;
    }

    // Create project
    const created = (await this.api(
      'POST',
      `/workspaces/${this.config.clockifyWorkspaceId}/projects`,
      { name: this.config.projectId },
    )) as ClockifyProject;

    this.projectId = created.id;
    return this.projectId;
  }

  private async createTimeEntry(
    start: Date,
    end: Date,
    description: string,
    projectId: string,
  ): Promise<TimeEntry> {
    return (await this.api(
      'POST',
      `/workspaces/${this.config.clockifyWorkspaceId}/time-entries`,
      {
        start: start.toISOString(),
        end: end.toISOString(),
        description,
        projectId,
      },
    )) as TimeEntry;
  }

  private async api(method: string, path: string, body?: unknown): Promise<unknown> {
    const url = `https://api.clockify.me/api/v1${path}`;
    const res = await fetch(url, {
      method,
      headers: {
        'X-Api-Key': this.config.clockifyApiKey!,
        'Content-Type': 'application/json',
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Clockify API ${res.status}: ${text}`);
    }

    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }

  destroy(): void {
    this.stop();
    if (this._idleCheckTimer) {
      clearInterval(this._idleCheckTimer);
      this._idleCheckTimer = null;
    }
    if (this._eodCheckTimer) {
      clearInterval(this._eodCheckTimer);
      this._eodCheckTimer = null;
    }
  }
}
