import { EventEmitter } from 'events';
import { execSync, spawn, type ChildProcess } from 'child_process';
import { existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PTY_HELPER = join(__dirname, 'pty-helper.py');

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

export type SessionMode =
  | { type: 'new' }
  | { type: 'continue' }           // --continue: resume most recent
  | { type: 'resume'; id: string }; // --resume <id>: resume specific session

export class ClaudeSession extends EventEmitter {
  private proc: ChildProcess | null = null;
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

    // Build claude args based on session mode
    const claudeArgs = ['--dangerously-skip-permissions'];
    switch (this._mode.type) {
      case 'continue':
        claudeArgs.push('--continue');
        break;
      case 'resume':
        claudeArgs.push('--resume', this._mode.id);
        break;
    }

    // Use Python pty helper to allocate a real PTY for Claude
    this.proc = spawn('python3', [
      PTY_HELPER,
      String(this.cols),
      String(this.rows),
      claudePath,
      ...claudeArgs,
    ], {
      cwd: this.projectPath,
      env: {
        ...process.env,
        TERM: 'xterm-256color',
        COLUMNS: String(this.cols),
        LINES: String(this.rows),
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    this._running = true;

    this.proc.stdout?.on('data', (data: Buffer) => {
      this._lastActivity = Date.now();
      this.emit('data', data.toString());
    });

    this.proc.stderr?.on('data', (data: Buffer) => {
      // Forward stderr as well (some Claude output goes here)
      this._lastActivity = Date.now();
      this.emit('data', data.toString());
    });

    this.proc.on('exit', (code) => {
      this._running = false;
      this.emit('exit', code ?? 0);
    });

    this.proc.on('error', (err) => {
      this._running = false;
      this.emit('error', err);
      this.emit('exit', 1);
    });
  }

  write(data: string): void {
    this.proc?.stdin?.write(data);
  }

  resize(cols: number, rows: number): void {
    this.cols = cols;
    this.rows = rows;
    // Send resize command via pty-helper stdin protocol
    this.proc?.stdin?.write(`\x1b]orch-resize;${cols};${rows}\x07`);
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
      this.proc.kill('SIGTERM');
      this.proc = null;
    }
  }
}
