import { app, BrowserWindow, ipcMain, shell } from 'electron';
import { join, resolve } from 'path';
import { execSync, spawn } from 'child_process';
import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'fs';
import { IPC } from '../shared/ipc';
import type { StatusBarData } from '../shared/ipc';
import { Config } from './config';
import { ClaudeSession } from './claude-session';
import type { SessionMode } from './claude-session';
import { ClockifyService } from './services/clockify';
import { createTracker } from './services/tracker';
import type { TrackerService } from './services/tracker';
import { CommandHistoryService } from './services/command-history';
import { OverlayManager } from './overlay-manager';
import type { StatusBarState } from './status-bar-state';
import { showMainMenu } from './overlays/main-menu';

// --- Parse CLI args ---
// Electron argv: [electron, app-path, ...user-args]
// Filter out Electron internal flags (--inspect, --remote-debugging-port, etc.)
const rawArgv = process.argv.slice(2); // skip electron binary and app path
const argv = rawArgv.filter(a => !a.startsWith('--inspect') && !a.startsWith('--remote-debugging'));

console.log('[orch3] argv:', argv);
console.log('[orch3] cwd:', process.cwd());

let projectPath = process.cwd();
let sessionMode: SessionMode = { type: 'new' };

for (let i = 0; i < argv.length; i++) {
  const arg = argv[i]!;
  switch (arg) {
    case '-c':
    case '--continue':
      sessionMode = { type: 'continue' };
      break;
    case '-r':
    case '--resume': {
      const id = argv[++i];
      if (!id) { console.error('--resume requires a session ID'); process.exit(1); }
      sessionMode = { type: 'resume', id };
      break;
    }
    default:
      if (!arg.startsWith('-')) projectPath = arg;
  }
}
projectPath = resolve(projectPath);
console.log('[orch3] projectPath:', projectPath);

// --- App state ---
let win: BrowserWindow;
let config: Config;
let session: ClaudeSession;
let clockify: ClockifyService;
let tracker: TrackerService;
let history: CommandHistoryService;
let overlay: OverlayManager;
let statusState: StatusBarState;
let statusInterval: ReturnType<typeof setInterval> | null = null;
let gitPollInterval: ReturnType<typeof setInterval> | null = null;
let lastCommand = '';
let lastPtyOutputTime = 0;
let inputBuffer = '';

// --- Scrollback buffer (ring buffer of recent PTY output) ---
const SCROLLBACK_MAX = 256 * 1024; // 256KB of recent output
let scrollbackBuf = '';

function appendScrollback(data: string): void {
  scrollbackBuf += data;
  if (scrollbackBuf.length > SCROLLBACK_MAX * 1.5) {
    scrollbackBuf = scrollbackBuf.slice(-SCROLLBACK_MAX);
  }
}

function saveScrollback(): void {
  try {
    const orchDir = join(projectPath, '.orch');
    mkdirSync(orchDir, { recursive: true });
    writeFileSync(join(orchDir, 'scrollback.buf'), scrollbackBuf);
  } catch { /* best effort */ }
}

function loadScrollback(): string {
  try {
    const bufPath = join(projectPath, '.orch', 'scrollback.buf');
    if (existsSync(bufPath)) {
      const data = readFileSync(bufPath, 'utf-8');
      // Delete after loading — one-shot restore
      const { unlinkSync } = require('fs');
      unlinkSync(bufPath);
      return data;
    }
  } catch { /* best effort */ }
  return '';
}

// Strip sequences from replayed scrollback that would set terminal modes
// or trigger query responses from xterm.js, while preserving visual formatting
function sanitizeScrollback(data: string): string {
  return data
    .replace(/\x1bc/g, '')                    // RIS (full terminal reset)
    .replace(/\x1b\[3J/g, '')                 // clear scrollback
    .replace(/\x1b\[([>?=])?c/g, '')          // DA queries (trigger responses)
    .replace(/\x1b\[6n/g, '')                 // cursor position report query
    .replace(/\x1b\[\?1004[hl]/g, '')         // focus reporting
    .replace(/\x1b\[\?100[0-6][hl]/g, '')     // mouse tracking modes
    .replace(/\x1b\[\?2004[hl]/g, '')         // bracketed paste
    .replace(/\x1b\[\?1049[hl]/g, '')         // alternate screen buffer
    .replace(/\x1b\[\?47[hl]/g, '')           // alternate screen (old)
    .replace(/\x1b\[\?1[hl]/g, '')            // application cursor keys
    .replace(/\x1b\[>[0-9;]*[a-zA-Z]/g, '')  // extended/kitty keyboard
    .replace(/\x1b\[\?u/g, '')                // kitty keyboard query
    .replace(/\x1b\[>[0-9]*u/g, '');          // kitty keyboard push
}

function createWindow(): void {
  win = new BrowserWindow({
    width: 1200,
    height: 800,
    // title set dynamically by renderer via document.title
    backgroundColor: '#1e1e1e',
    webPreferences: {
      preload: join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  win.loadFile(join(__dirname, '..', 'renderer', 'index.html'));

  // Initialize services
  config = new Config(projectPath);

  // Title is set in sendStatusUpdate() after config is available
  clockify = new ClockifyService(config);
  tracker = createTracker(config);
  history = new CommandHistoryService(join(projectPath, '.orch'));

  // Restore lastCommand from history so status bar survives reloads
  const recentCmds = history.getRecent(1);
  if (recentCmds.length > 0) {
    lastCommand = recentCmds[0]!.cmd;
  }

  // Wire up AI summary provider for Clockify
  clockify.setSummaryProvider(async () => {
    const entries = history.getSinceLastFlush();
    if (entries.length === 0) return `Active work on ${config.projectId}`;

    const cmds = [...new Set(entries.map((e) => e.cmd))];
    const cmdList = cmds.slice(-20).join('\n');

    const apiKey = config.anthropicApiKey;
    if (apiKey) {
      try {
        const res = await fetch('https://api.anthropic.com/v1/messages', {
          method: 'POST',
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            model: 'claude-haiku-4-5-20251001',
            max_tokens: 100,
            messages: [{
              role: 'user',
              content: `Summarize this developer's work session in 1-2 brief phrases for a time tracking entry (max 120 chars). Only output the summary, nothing else.\n\nCommands run:\n${cmdList}`,
            }],
          }),
        });
        if (res.ok) {
          const data = await res.json() as any;
          const text = data?.content?.[0]?.text?.trim();
          if (text) {
            history.markFlushed();
            return text.length > 120 ? text.slice(0, 117) + '...' : text;
          }
        }
      } catch { /* fall through to fallback */ }
    }

    // Fallback: deduplicated command join
    history.markFlushed();
    const summary = cmds.slice(-5).join('; ');
    return summary.length > 120 ? summary.slice(0, 117) + '...' : summary;
  });
  overlay = new OverlayManager(win);
  statusState = { currentIssue: null, gitBranch: '', gitDirty: false };

  // Write PID file so the launcher can detect/focus this instance
  try {
    writeFileSync(join(config.orchDir, 'orch3.pid'), String(process.pid));
  } catch { /* best effort */ }

  console.log('[orch3] config.projectName:', config.projectName);
  console.log('[orch3] config.projectPath:', config.projectPath);
}

let stripResetSeqs = false;

function spawnSession(cols: number, rows: number): void {
  console.log('[orch3] spawnSession:', cols, 'x', rows);

  // Ensure reasonable dimensions
  if (cols < 10) cols = 80;
  if (rows < 5) rows = 24;

  session = new ClaudeSession(projectPath, cols, rows, sessionMode);

  session.on('data', (data: string) => {
    // Strip terminal reset/clear-scrollback sequences from the first output
    // so they don't wipe replayed scrollback from a previous session
    if (stripResetSeqs) {
      stripResetSeqs = false;
      data = data
        .replace(/\x1bc/g, '\x1b[!p\x1b[2J\x1b[H') // RIS → soft reset + clear screen (preserves scrollback)
        .replace(/\x1b\[3J/g, '');                     // strip clear-scrollback
    }
    // Always suppress alternate screen buffer switching — Claude Code uses it
    // for its status UI, but orch3 has its own status bar. Switching to alternate
    // screen causes xterm.js to swap to a blank buffer (the "scroll jump to top").
    data = data
      .replace(/\x1b\[\?1049h/g, '')   // enter alternate screen
      .replace(/\x1b\[\?1049l/g, '')   // leave alternate screen
      .replace(/\x1b\[\?47h/g, '')     // enter alternate screen (old)
      .replace(/\x1b\[\?47l/g, '');    // leave alternate screen (old)
    appendScrollback(data);
    lastPtyOutputTime = Date.now();
    if (!win.isDestroyed()) {
      win.webContents.send(IPC.PTY_DATA, data);
    }
    clockify.onActivity();
  });

  session.on('exit', (code: number) => {
    console.log('[orch3] session exited:', code);
    if (!win.isDestroyed()) {
      win.webContents.send(IPC.SESSION_EXIT, code);
    }
  });

  try {
    session.spawn();
    console.log('[orch3] session spawned successfully');
  } catch (err) {
    console.error('[orch3] Failed to spawn session:', err);
  }
}

function pollGitInfo(): void {
  try {
    statusState.gitBranch = execSync('git rev-parse --abbrev-ref HEAD', {
      cwd: config.projectPath,
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    const status = execSync('git status --short', {
      cwd: config.projectPath,
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    statusState.gitDirty = status.length > 0;
  } catch {
    statusState.gitBranch = '';
    statusState.gitDirty = false;
  }
}

function sendStatusUpdate(): void {
  if (win.isDestroyed()) return;
  win.setTitle(`orch3 - ${config.projectName}`);
  const data: StatusBarData = {
    claudeActive: (Date.now() - lastPtyOutputTime) < 2000,
    projectName: config.projectName,
    timeElapsed: clockify.formatElapsed(),
    timeRecording: clockify.recording,
    trackerEnabled: tracker.enabled,
    trackerTeamKey: tracker.teamKey,
    currentIssueKey: statusState.currentIssue?.key,
    currentIssueTitle: statusState.currentIssue?.title,
    gitBranch: statusState.gitBranch,
    gitDirty: statusState.gitDirty,
    lastCommand,
  };
  win.webContents.send(IPC.STATUS_UPDATE, data);
}

function refreshTracker(): void {
  config.reload();
  tracker = createTracker(config);
}

function openMainMenu(): void {
  showMainMenu(
    overlay,
    config,
    clockify,
    tracker,
    history,
    session,
    statusState,
    () => refreshTracker(),
    () => sendStatusUpdate(),
  );
}

// --- IPC handlers ---
function setupIpc(): void {
  ipcMain.on(IPC.APP_READY, (_e, data: any) => {
    const cols = data?.cols || 80;
    const rows = data?.rows || 24;
    console.log('[orch3] APP_READY received:', cols, 'x', rows);

    // Replay saved scrollback from previous session
    const saved = loadScrollback();
    if (saved) {
      console.log('[orch3] replaying scrollback:', saved.length, 'bytes');
      scrollbackBuf = saved; // seed the ring buffer so it persists across multiple refreshes
      const clean = sanitizeScrollback(saved);
      if (clean && !win.isDestroyed()) {
        win.webContents.send(IPC.PTY_DATA, clean);
      }
      // Protect replayed scrollback from reset sequences in the new session's first output
      stripResetSeqs = true;
    }

    spawnSession(cols, rows);
    pollGitInfo();
    sendStatusUpdate();

    statusInterval = setInterval(() => sendStatusUpdate(), 1000);
    gitPollInterval = setInterval(() => pollGitInfo(), 10000);
  });

  ipcMain.on(IPC.PTY_INPUT, (_e, data: string) => {
    // Track user input to capture last command
    if (data === '\r' || data === '\n') {
      const cmd = inputBuffer.trim();
      if (cmd) {
        lastCommand = cmd;
        history.append(cmd);
        sendStatusUpdate();
      }
      inputBuffer = '';
    } else if (data === '\x7f') {
      // Backspace
      inputBuffer = inputBuffer.slice(0, -1);
    } else if (data.length === 1 && data.charCodeAt(0) >= 32) {
      inputBuffer += data;
    }
    if (session?.running) session.write(data);
  });

  ipcMain.on(IPC.PTY_RESIZE, (_e, data: any) => {
    const cols = data?.cols || 80;
    const rows = data?.rows || 24;
    if (session?.running) session.resize(cols, rows);
  });

  ipcMain.on(IPC.HOTKEY, (_e, key: string) => {
    console.log('[orch3] hotkey:', key);
    switch (key) {
      case 'f1':
        openMainMenu();
        break;
      case 'f5': {
        saveScrollback();
        if (clockify.recording) clockify.flush().catch(() => {});
        session?.kill();
        // Relaunch via orch3 (on PATH) so it resolves the latest tag
        const child = spawn('orch3', [projectPath, '--continue'], {
          detached: true,
          stdio: 'ignore',
          cwd: projectPath,
          shell: true,
        });
        child.unref();
        app.exit(0);
        break;
      }
      case 'ctrl+r': {
        saveScrollback();
        session?.kill();
        // Get current terminal size from the renderer
        const cols = 120;
        const rows = 40;
        sessionMode = { type: 'continue' };
        spawnSession(cols, rows);
        break;
      }
    }
  });

  ipcMain.on(IPC.OVERLAY_KEY, (_e, key: string, rawBytes?: number[]) => {
    overlay.handleKey(key, rawBytes);
  });

  ipcMain.on(IPC.OPEN_URL, (_e, url: string) => {
    shell.openExternal(url);
  });
}

// --- App lifecycle ---
// Set process name so macOS shows "orch3-projectname" instead of "Electron"
const appName = `orch3-${projectPath.split('/').pop()}`;
app.setName(appName);
process.title = appName;

// Focus window when receiving SIGUSR1 (used by launcher to bring window to front)
process.on('SIGUSR1', () => {
  if (win && !win.isDestroyed()) {
    win.show();
    win.focus();
  }
});

// Move/resize window when receiving SIGUSR2 (used by launcher for cascade)
process.on('SIGUSR2', () => {
  try {
    const cmdPath = join(projectPath, '.orch', 'window-cmd.json');
    if (existsSync(cmdPath)) {
      const cmd = JSON.parse(readFileSync(cmdPath, 'utf-8'));
      if (win && !win.isDestroyed() && cmd.x !== undefined && cmd.y !== undefined) {
        win.setPosition(cmd.x, cmd.y);
        if (cmd.focus) {
          win.show();
          win.focus();
        }
      }
      const { unlinkSync } = require('fs');
      unlinkSync(cmdPath);
    }
  } catch { /* best effort */ }
});

app.whenReady().then(() => {
  console.log('[orch3] app ready');
  setupIpc();
  createWindow();
});

app.on('window-all-closed', () => {
  if (clockify?.recording) clockify.flush().catch(() => {});
  if (statusInterval) clearInterval(statusInterval);
  if (gitPollInterval) clearInterval(gitPollInterval);
  clockify?.destroy();
  session?.kill();
  // Clean up PID file
  try {
    const { unlinkSync } = require('fs');
    unlinkSync(join(projectPath, '.orch', 'orch3.pid'));
  } catch { /* best effort */ }
  app.quit();
});
