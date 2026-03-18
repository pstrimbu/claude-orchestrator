import type { Config } from '../config.js';

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
  private _actions: string[] = [];
  private _flushTimer: ReturnType<typeof setInterval> | null = null;
  private _activityTimer: ReturnType<typeof setInterval> | null = null;
  private _lastActivityCheck = 0;

  constructor(private config: Config) {}

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

  logAction(description: string): void {
    this._actions.push(description);
    // Keep last 50 actions
    if (this._actions.length > 50) this._actions.shift();
  }

  // Track activity from PTY output — call this when Claude produces output
  onActivity(): void {
    this._lastActivityCheck = Date.now();
    // Auto-start if not recording
    if (!this._recording && this.enabled) {
      this.start();
    }
  }

  async flush(): Promise<{ success: boolean; entryId?: string; error?: string }> {
    if (!this.enabled) return { success: false, error: 'Clockify not configured' };

    const seconds = this.elapsed;
    if (seconds < 60) return { success: false, error: 'Less than 1 minute accumulated' };

    // Build summary from actions
    const summary = this.buildSummary();

    // Calculate start/end times
    const end = new Date();
    const start = new Date(end.getTime() - seconds * 1000);

    try {
      const projectId = await this.ensureProject();
      if (!projectId) return { success: false, error: 'Could not find/create Clockify project' };

      const entry = await this.createTimeEntry(start, end, summary, projectId);

      // Reset state
      this._accumulated = 0;
      this._startTime = this._recording ? new Date() : null;
      this._actions = [];

      return { success: true, entryId: entry.id };
    } catch (err: any) {
      return { success: false, error: err.message };
    }
  }

  private buildSummary(): string {
    if (this._actions.length === 0) {
      return `Active work on ${this.config.projectId}`;
    }
    // Deduplicate and take last few
    const unique = [...new Set(this._actions)];
    const summary = unique.slice(-3).join('; ');
    return summary.length > 120 ? summary.slice(0, 117) + '...' : summary;
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
    if (this._activityTimer) {
      clearInterval(this._activityTimer);
      this._activityTimer = null;
    }
  }
}
