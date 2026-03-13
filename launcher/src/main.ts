import { app, BrowserWindow, ipcMain, dialog, screen } from 'electron';
import { join } from 'path';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { execSync, spawn } from 'child_process';

interface ProjectEntry {
  path: string;
  name: string;
}

interface ProjectStatus {
  path: string;
  name: string;
  running: boolean;
  pid: number | null;
}

// --- Config ---
const CONFIG_DIR = join(app.getPath('home'), '.config', 'orch3');
const CONFIG_FILE = join(CONFIG_DIR, 'launcher-projects.json');

function loadProjects(): ProjectEntry[] {
  if (!existsSync(CONFIG_FILE)) return [];
  try {
    const data = JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
    return data.projects || [];
  } catch { return []; }
}

function saveProjects(projects: ProjectEntry[]): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(CONFIG_FILE, JSON.stringify({ projects }, null, 2));
}

// --- Process detection ---
function getRunningPid(projectPath: string): number | null {
  // Check PID file first
  const pidFile = join(projectPath, '.orch', 'orch3.pid');
  if (existsSync(pidFile)) {
    try {
      const pid = parseInt(readFileSync(pidFile, 'utf-8').trim(), 10);
      if (pid > 0) {
        // Verify process is alive
        process.kill(pid, 0);
        return pid;
      }
    } catch { /* process dead or bad PID file */ }
  }

  // Fallback: parse ps
  try {
    const out = execSync(
      `ps axo pid,args | grep 'Electron.*${projectPath}' | grep -v grep | grep -v Helper | head -1`,
      { encoding: 'utf-8' },
    ).trim();
    if (out) {
      const pid = parseInt(out.trim().split(/\s+/)[0]!, 10);
      if (pid > 0) return pid;
    }
  } catch { /* no match */ }

  return null;
}

function getStatuses(projects: ProjectEntry[]): ProjectStatus[] {
  return projects.map((p) => {
    const pid = getRunningPid(p.path);
    return { ...p, running: pid !== null, pid };
  });
}

function focusWindow(pid: number): void {
  try {
    execSync(`osascript -e '
      tell application "System Events"
        set targetProc to first process whose unix id is ${pid}
        set frontmost of targetProc to true
      end tell
    '`);
  } catch (e) {
    console.error('[launcher] focus failed:', e);
  }
}

function openProject(projectPath: string): void {
  const child = spawn('orch3', [projectPath, '--continue'], {
    detached: true,
    stdio: 'ignore',
    shell: true,
    cwd: projectPath,
  });
  child.unref();
}

function stopProject(pid: number): void {
  try {
    process.kill(pid, 'SIGTERM');
  } catch { /* already dead */ }
}

function cascadeWindows(): void {
  const statuses = getStatuses(projects);
  const running = statuses.filter((s) => s.running && s.pid);
  if (running.length === 0) return;

  // Sort alphabetically by project name
  running.sort((a, b) => a.name.localeCompare(b.name));

  const display = screen.getPrimaryDisplay();
  const { width: screenW, height: screenH } = display.workAreaSize;
  const workAreaTop = display.workArea.y;

  const maxOffsetX = 30;
  const maxOffsetY = 80;

  // Get window size of first window to position bottom edge at dock
  let winW = 1200;
  let winH = 800;
  try {
    const sizeStr = execSync(
      `osascript -e 'tell application "System Events" to get size of window 1 of (first process whose unix id is ${running[0]!.pid})'`,
      { encoding: 'utf-8' },
    ).trim();
    const parts = sizeStr.split(',');
    winW = parseInt(parts[0]!.trim(), 10) || 1200;
    winH = parseInt(parts[1]!.trim(), 10) || 800;
  } catch { /* use default */ }

  // Position so bottom of first window abuts the dock
  const baseX = Math.round((screenW - winW) / 2);
  const baseY = workAreaTop + screenH - winH;

  // Calculate spacing so all windows fit between dock and menu bar
  const availableY = baseY - workAreaTop;
  const gaps = running.length - 1;
  const offsetY = gaps > 0 ? Math.min(maxOffsetY, Math.floor(availableY / gaps)) : 0;
  const offsetX = gaps > 0 ? Math.min(maxOffsetX, Math.floor(offsetY * maxOffsetX / maxOffsetY)) : 0;

  // Build a single osascript — last-to-first so first ends up on top
  const commands: string[] = [];
  for (let i = running.length - 1; i >= 0; i--) {
    const s = running[i]!;
    const x = baseX + offsetX * i;
    const y = baseY - offsetY * i;
    commands.push(
      `set position of window 1 of (first process whose unix id is ${s.pid}) to {${x}, ${y}}`,
      `set frontmost of (first process whose unix id is ${s.pid}) to true`,
    );
  }

  const script = `tell application "System Events"\n${commands.join('\n')}\nend tell`;
  try {
    execSync(`osascript -e '${script.replace(/'/g, "'\"'\"'")}'`);
  } catch (e) {
    console.error('[launcher] cascade failed:', e);
  }
}

// --- Window ---
let win: BrowserWindow;
let pollInterval: ReturnType<typeof setInterval> | null = null;
let projects: ProjectEntry[] = [];

const COLLAPSED_WIDTH = 40;
const EXPANDED_WIDTH = 300;
const WIN_HEIGHT = 500;
let expanded = false;

function createWindow(): void {
  const display = screen.getPrimaryDisplay();
  const { width: screenW } = display.workAreaSize;

  win = new BrowserWindow({
    width: COLLAPSED_WIDTH,
    height: WIN_HEIGHT,
    x: screenW - COLLAPSED_WIDTH,
    y: 80,
    minWidth: COLLAPSED_WIDTH,
    minHeight: 100,
    maxWidth: EXPANDED_WIDTH,
    alwaysOnTop: true,
    frame: false,
    transparent: false,
    backgroundColor: '#1e1e1e',
    resizable: false,
    skipTaskbar: true,
    webPreferences: {
      preload: join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  win.loadFile(join(__dirname, 'renderer', 'index.html'));

  projects = loadProjects();
  sendUpdate();
  pollInterval = setInterval(() => sendUpdate(), 3000);
}

function expandWindow(): void {
  if (expanded || win.isDestroyed()) return;
  expanded = true;
  const [x, y] = win.getPosition();
  win.setBounds({ x: x - (EXPANDED_WIDTH - COLLAPSED_WIDTH), y, width: EXPANDED_WIDTH, height: WIN_HEIGHT });
  win.webContents.send('expanded', true);
}

function collapseWindow(): void {
  if (!expanded || win.isDestroyed()) return;
  expanded = false;
  const [x, y] = win.getPosition();
  win.setBounds({ x: x + (EXPANDED_WIDTH - COLLAPSED_WIDTH), y, width: COLLAPSED_WIDTH, height: WIN_HEIGHT });
  win.webContents.send('expanded', false);
}

function sendUpdate(): void {
  if (win.isDestroyed()) return;
  const statuses = getStatuses(projects);
  win.webContents.send('projects:update', statuses);
}

// --- IPC ---
ipcMain.handle('projects:add', async () => {
  const result = await dialog.showOpenDialog(win, {
    properties: ['openDirectory'],
    defaultPath: join(app.getPath('home'), 'dev'),
  });
  if (result.canceled || result.filePaths.length === 0) return;
  const dirPath = result.filePaths[0]!;
  const name = dirPath.split('/').pop()!;

  if (projects.some((p) => p.path === dirPath)) return; // already exists
  projects.push({ path: dirPath, name });
  saveProjects(projects);
  sendUpdate();
});

ipcMain.on('projects:remove', (_e, path: string) => {
  projects = projects.filter((p) => p.path !== path);
  saveProjects(projects);
  sendUpdate();
});

ipcMain.on('projects:open', (_e, path: string) => {
  openProject(path);
  // Poll quickly to catch the new process
  setTimeout(() => sendUpdate(), 2000);
  setTimeout(() => sendUpdate(), 5000);
});

ipcMain.on('projects:focus', (_e, pid: number) => {
  focusWindow(pid);
});

ipcMain.on('projects:stop', (_e, pid: number) => {
  stopProject(pid);
  setTimeout(() => sendUpdate(), 1000);
});

ipcMain.on('projects:cascade', () => {
  cascadeWindows();
});

ipcMain.on('window:expand', () => expandWindow());
ipcMain.on('window:collapse', () => collapseWindow());

ipcMain.on('projects:reorder', (_e, paths: string[]) => {
  const byPath = new Map(projects.map((p) => [p.path, p]));
  projects = paths.map((p) => byPath.get(p)).filter((p): p is ProjectEntry => !!p);
  saveProjects(projects);
});

// --- Lifecycle ---
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (win && !win.isDestroyed()) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });

  app.whenReady().then(createWindow);

  app.on('window-all-closed', () => {
    if (pollInterval) clearInterval(pollInterval);
    app.quit();
  });
}
