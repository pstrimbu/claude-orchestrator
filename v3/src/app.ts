import { Screen } from './screen.js';
import { ClaudeSession } from './claude-session.js';
import type { SessionMode } from './claude-session.js';
import { StatusBar } from './status-bar.js';
import { OverlayManager } from './overlay.js';
import { ClockifyService } from './services/clockify.js';
import { createTracker } from './services/tracker.js';
import { Config } from './config.js';
import { keyName } from './ansi.js';
import { showMainMenu } from './overlays/main-menu.js';
import { execSync, spawn as cpSpawn } from 'child_process';

export class App {
  private screen: Screen;
  private session: ClaudeSession;
  private statusBar: StatusBar;
  private overlay: OverlayManager;
  private clockify: ClockifyService;
  private config: Config;
  private tracker: ReturnType<typeof createTracker>;
  private sessionMode: SessionMode;
  private statusInterval: ReturnType<typeof setInterval> | null = null;
  private gitPollInterval: ReturnType<typeof setInterval> | null = null;

  constructor(projectPath: string, sessionMode: SessionMode = { type: 'new' }) {
    this.config = new Config(projectPath);
    this.sessionMode = sessionMode;
    this.screen = new Screen();
    this.clockify = new ClockifyService(this.config);
    this.tracker = createTracker(this.config);
    this.overlay = new OverlayManager(this.screen);

    this.session = new ClaudeSession(
      this.config.projectPath,
      this.screen.cols,
      this.screen.sessionRows,
      this.sessionMode,
    );

    this.statusBar = new StatusBar(
      this.screen,
      this.config,
      this.clockify,
      this.tracker,
    );
  }

  async start(): Promise<void> {
    // Setup terminal
    this.screen.setup();

    // Re-read terminal dimensions now that we're fully attached,
    // then resize the session to match before spawning
    this.screen.resize();
    this.session.resize(this.screen.cols, this.screen.sessionRows);

    // Enable raw mode for stdin
    if (process.stdin.isTTY) {
      process.stdin.setRawMode(true);
    }
    process.stdin.resume();
    process.stdin.setEncoding('utf-8');

    // Initial git info
    this.pollGitInfo();

    // Render initial status bar
    this.statusBar.render();

    // Spawn Claude session
    this.session.spawn();

    // Wire PTY output to screen
    this.session.on('data', (data: string) => {
      this.screen.writeToSession(data);
      this.clockify.onActivity();
    });

    // Handle session exit
    this.session.on('exit', (code: number) => {
      this.shutdown(code);
    });

    // Wire stdin to PTY or overlay
    process.stdin.on('data', (data: string) => {
      this.handleInput(Buffer.from(data));
    });

    // Handle terminal resize
    process.stdout.on('resize', () => {
      this.screen.resize();
      this.session.resize(this.screen.cols, this.screen.sessionRows);
      this.statusBar.render();
    });

    // Periodic status bar refresh (for timer display)
    this.statusInterval = setInterval(() => this.statusBar.render(), 1000);

    // Periodic git info poll
    this.gitPollInterval = setInterval(() => this.pollGitInfo(), 10000);

    // Handle cleanup signals
    const cleanup = () => this.shutdown(0);
    process.on('SIGINT', cleanup);
    process.on('SIGTERM', cleanup);
  }

  private handleInput(data: Buffer): void {
    const str = data.toString();

    // If overlay is active, route all input to overlay
    if (this.overlay.active) {
      this.overlay.handleKey(data);
      return;
    }

    // Check for our hotkeys (F-keys open overlays)
    const key = keyName(data);
    if (this.handleHotkey(key)) return;

    // Forward everything else to the Claude session
    this.session.write(str);
  }

  private handleHotkey(key: string): boolean {
    switch (key) {
      case 'f13':
        this.openMainMenu();
        return true;
      case 'f5':
        this.reload();
        return true;
      case 'ctrl+r':
        this.restartSession();
        return true;
      default:
        return false;
    }
  }

  // F5: Full reload — re-exec orch3 process (picks up code changes)
  private reload(): void {
    if (this.clockify.recording) {
      this.clockify.flush().catch(() => {});
    }

    if (this.statusInterval) clearInterval(this.statusInterval);
    if (this.gitPollInterval) clearInterval(this.gitPollInterval);
    this.clockify.destroy();
    this.session.kill();
    this.screen.cleanup();

    if (process.stdin.isTTY) {
      process.stdin.setRawMode(false);
    }
    process.stdin.pause();

    // Re-exec with same args
    const child = cpSpawn(process.argv[0]!, process.argv.slice(1), {
      stdio: 'inherit',
      cwd: process.cwd(),
      env: process.env,
    });
    child.on('exit', (code) => process.exit(code ?? 0));
  }

  // Ctrl+R: Restart just the Claude session (keeps timer, config)
  // Uses --continue to preserve conversation history
  private restartSession(): void {
    this.session.kill();
    this.screen.clearOverlay();

    // Spawn fresh session with --continue to preserve conversation history
    this.session = new ClaudeSession(
      this.config.projectPath,
      this.screen.cols,
      this.screen.sessionRows,
      { type: 'continue' },
    );

    this.session.on('data', (data: string) => {
      this.screen.writeToSession(data);
      this.clockify.onActivity();
    });

    this.session.on('exit', (code: number) => {
      this.shutdown(code);
    });

    this.session.spawn();
    this.statusBar.render();
  }

  refreshTracker(): void {
    this.config.reload();
    this.tracker = createTracker(this.config);
    // Update status bar with new tracker
    (this.statusBar as any).tracker = this.tracker;
  }

  private openMainMenu(): void {
    showMainMenu(
      this.overlay,
      this.config,
      this.clockify,
      this.tracker,
      this.session,
      this.statusBar,
      () => this.refreshTracker(),
      () => this.statusBar.render(),
    );
  }

  private pollGitInfo(): void {
    try {
      this.statusBar.gitBranch = execSync('git rev-parse --abbrev-ref HEAD', {
        cwd: this.config.projectPath,
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();

      const status = execSync('git status --short', {
        cwd: this.config.projectPath,
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
      this.statusBar.gitDirty = status.length > 0;
    } catch {
      this.statusBar.gitBranch = '';
      this.statusBar.gitDirty = false;
    }
  }

  private shutdown(code: number): void {
    // Flush clockify before exit
    if (this.clockify.recording) {
      this.clockify.flush().catch(() => {});
    }

    if (this.statusInterval) clearInterval(this.statusInterval);
    if (this.gitPollInterval) clearInterval(this.gitPollInterval);

    this.clockify.destroy();
    this.session.kill();
    this.screen.cleanup();

    if (process.stdin.isTTY) {
      process.stdin.setRawMode(false);
    }
    process.stdin.pause();

    process.exit(code);
  }
}
