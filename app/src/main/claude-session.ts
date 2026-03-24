import { EventEmitter } from 'events';
import { execSync } from 'child_process';
import { existsSync } from 'fs';
import * as pty from 'node-pty';

export type SessionMode =
  | { type: 'new' }
  | { type: 'continue' }
  | { type: 'resume'; id: string };

function resolveClaudePath(): string {
  const attempts = [
    () => execSync('bash -lc "which claude"', { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }).trim(),
    () => execSync('zsh -lc "which claude"', { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }).trim(),
  ];

  for (const attempt of attempts) {
    try {
      const path = attempt();
      if (path && !path.includes('not found')) return path;
    } catch { /* try next */ }
  }

  const common = [
    `${process.env.HOME}/.local/bin/claude`,
    `${process.env.HOME}/.claude/bin/claude`,
    '/usr/local/bin/claude',
    '/opt/homebrew/bin/claude',
  ];
  for (const p of common) {
    if (existsSync(p)) return p;
  }

  throw new Error('Could not find "claude" binary.');
}

export class ClaudeSession extends EventEmitter {
  private proc: pty.IPty | null = null;
  private _lastActivity = Date.now();
  private _running = false;
  private _mode: SessionMode = { type: 'new' };

  constructor(
    private projectPath: string,
    private cols: number,
    private rows: number,
    mode?: SessionMode,
  ) {
    super();
    if (mode) this._mode = mode;
  }

  get mode(): SessionMode {
    return this._mode;
  }

  spawn(): void {
    const claudePath = resolveClaudePath();

    const args = ['--dangerously-skip-permissions'];
    switch (this._mode.type) {
      case 'continue':
        args.push('--continue');
        break;
      case 'resume':
        args.push('--resume', this._mode.id);
        break;
    }

    // Strip ANTHROPIC_API_KEY so Claude CLI uses the subscription auth
    // (project .env files may set it for app use, but it shouldn't leak into the CLI)
    const { ANTHROPIC_API_KEY: _removed, ...cleanEnv } = process.env;

    this.proc = pty.spawn(claudePath, args, {
      name: 'xterm-256color',
      cols: this.cols,
      rows: this.rows,
      cwd: this.projectPath,
      env: {
        ...cleanEnv,
        TERM: 'xterm-256color',
        COLUMNS: String(this.cols),
        LINES: String(this.rows),
      } as Record<string, string>,
    });

    this._running = true;

    this.proc.onData((data: string) => {
      this._lastActivity = Date.now();
      this.emit('data', data);
    });

    this.proc.onExit(({ exitCode }) => {
      this._running = false;
      this.emit('exit', exitCode);
    });
  }

  write(data: string): void {
    this.proc?.write(data);
  }

  resize(cols: number, rows: number): void {
    this.cols = cols;
    this.rows = rows;
    try {
      this.proc?.resize(cols, rows);
    } catch { /* ignore resize errors on dead process */ }
  }

  get running(): boolean {
    return this._running;
  }

  get lastActivity(): number {
    return this._lastActivity;
  }

  get idleSeconds(): number {
    return Math.floor((Date.now() - this._lastActivity) / 1000);
  }

  kill(): void {
    if (this.proc) {
      this._running = false;
      this.proc.kill();
      this.proc = null;
    }
  }
}
