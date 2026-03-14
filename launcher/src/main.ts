import { app, BrowserWindow, ipcMain, dialog, screen, shell } from 'electron';
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

interface PortalEntry {
  name: string;
  uiPort: number;
  apiPort: number;
  path: string;
  startCmd: string;
  visible: boolean;
}

interface PortalStatus {
  name: string;
  uiPort: number;
  apiPort: number;
  path: string;
  startCmd: string;
  uiRunning: boolean;
  apiRunning: boolean;
}

// --- Config ---
const CONFIG_DIR = join(app.getPath('home'), '.config', 'orch3');
const CONFIG_FILE = join(CONFIG_DIR, 'launcher-projects.json');
const PORTALS_CONFIG_FILE = join(CONFIG_DIR, 'launcher-portals.json');
const PORTS_CSV = join(app.getPath('home'), 'dev', 'dev-application-ports.csv');

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

// --- Portals ---
function loadPortsCsv(): { name: string; uiPort: number; apiPort: number; dir: string; startCmd: string }[] {
  if (!existsSync(PORTS_CSV)) return [];
  try {
    const lines = readFileSync(PORTS_CSV, 'utf-8').trim().split('\n');
    // Header: project,ui,api,db,redis,debug,dir,startCmd
    return lines.slice(1).filter(l => l.trim()).map(line => {
      const parts = line.split(',');
      return {
        name: parts[0]!.trim(),
        uiPort: parseInt(parts[1]!.trim(), 10),
        apiPort: parseInt(parts[2]!.trim(), 10),
        dir: parts[6]?.trim() || parts[0]!.trim(),
        startCmd: parts[7]?.trim() || 'npm run dev',
      };
    }).filter(p => p.uiPort > 0 && p.apiPort > 0);
  } catch { return []; }
}

function loadPortalsConfig(): { hidden: string[] } {
  if (!existsSync(PORTALS_CONFIG_FILE)) return { hidden: [] };
  try {
    return JSON.parse(readFileSync(PORTALS_CONFIG_FILE, 'utf-8'));
  } catch { return { hidden: [] }; }
}

function savePortalsConfig(cfg: { hidden: string[] }): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(PORTALS_CONFIG_FILE, JSON.stringify(cfg, null, 2));
}

function isPortListening(port: number): boolean {
  try {
    const out = execSync(`lsof -iTCP:${port} -sTCP:LISTEN -P -n 2>/dev/null | grep -c LISTEN`, {
      encoding: 'utf-8',
    }).trim();
    return parseInt(out, 10) > 0;
  } catch { return false; }
}

function getPortalEntries(): PortalEntry[] {
  const csvPortals = loadPortsCsv();
  const cfg = loadPortalsConfig();
  return csvPortals.map(p => ({
    name: p.name,
    uiPort: p.uiPort,
    apiPort: p.apiPort,
    path: join(app.getPath('home'), 'dev', p.dir),
    startCmd: p.startCmd,
    visible: !cfg.hidden.includes(p.name),
  }));
}

function getPortalStatuses(): PortalStatus[] {
  const entries = getPortalEntries();
  return entries.filter(e => e.visible).map(e => ({
    name: e.name,
    uiPort: e.uiPort,
    apiPort: e.apiPort,
    path: e.path,
    startCmd: e.startCmd,
    uiRunning: isPortListening(e.uiPort),
    apiRunning: isPortListening(e.apiPort),
  }));
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

function focusWindow(projectName: string): void {
  const winTitle = `orch3 - ${projectName}`;
  try {
    execSync(`osascript -e '
      tell application "System Events"
        set procs to every process whose name is "Electron"
        repeat with p in procs
          try
            repeat with w in (every window of p)
              if name of w contains "${winTitle}" then
                perform action "AXRaise" of w
                set frontmost of p to true
                return
              end if
            end repeat
          end try
        end repeat
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

  const maxOffset = 80;

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

  // Calculate spacing so all windows fit — same offset for both axes (diagonal)
  const availableY = baseY - workAreaTop;
  const gaps = running.length - 1;
  const offset = gaps > 0 ? Math.min(maxOffset, Math.floor(availableY / gaps)) : 0;

  // Build a single osascript — last-to-first so first ends up on top
  const commands: string[] = [];
  for (let i = running.length - 1; i >= 0; i--) {
    const s = running[i]!;
    const x = baseX + offset * i;
    const y = baseY - offset * i;
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

// --- Portal start/stop ---
function startPortal(portalPath: string, startCmd: string): void {
  const child = spawn(startCmd, {
    detached: true,
    stdio: 'ignore',
    shell: true,
    cwd: portalPath,
  });
  child.unref();
}

function stopPortal(port: number): void {
  try {
    const out = execSync(`lsof -iTCP:${port} -sTCP:LISTEN -P -n -t 2>/dev/null`, {
      encoding: 'utf-8',
    }).trim();
    if (out) {
      out.split('\n').forEach(pid => {
        try { process.kill(parseInt(pid, 10), 'SIGTERM'); } catch { /* */ }
      });
    }
  } catch { /* nothing listening */ }
}

// --- Window ---
let win: BrowserWindow;
let pollInterval: ReturnType<typeof setInterval> | null = null;
let projects: ProjectEntry[] = [];

const COLLAPSED_WIDTH = 40;
const EXPANDED_WIDTH = 300;
let expanded = false;

function createWindow(): void {
  const display = screen.getPrimaryDisplay();
  const { width: screenW } = display.workAreaSize;

  win = new BrowserWindow({
    width: COLLAPSED_WIDTH,
    height: 400,
    x: screenW - COLLAPSED_WIDTH,
    y: 80,
    minWidth: COLLAPSED_WIDTH,
    minHeight: 60,
    maxWidth: EXPANDED_WIDTH,
    show: false,
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

  win.webContents.on('did-finish-load', () => {
    // Small delay to ensure renderer JS has registered IPC listeners
    setTimeout(() => {
      sendUpdate();
      win.show();
    }, 200);
  });

  pollInterval = setInterval(() => sendUpdate(), 3000);
}

function expandWindow(): void {
  if (expanded || win.isDestroyed()) return;
  expanded = true;
  const [x, y] = win.getPosition();
  const h = win.getSize()[1];
  win.setBounds({ x: x - (EXPANDED_WIDTH - COLLAPSED_WIDTH), y, width: EXPANDED_WIDTH, height: h });
  win.webContents.send('expanded', true);
}

function collapseWindow(): void {
  if (!expanded || win.isDestroyed()) return;
  expanded = false;
  const [x, y] = win.getPosition();
  const h = win.getSize()[1];
  win.setBounds({ x: x + (EXPANDED_WIDTH - COLLAPSED_WIDTH), y, width: COLLAPSED_WIDTH, height: h });
  win.webContents.send('expanded', false);
}

function sendUpdate(): void {
  if (win.isDestroyed()) return;
  const statuses = getStatuses(projects);
  win.webContents.send('projects:update', statuses);
  const portalStatuses = getPortalStatuses();
  win.webContents.send('portals:update', portalStatuses);

  // Auto-size window to fit content
  const maxItems = Math.max(statuses.length, portalStatuses.length);
  const itemHeight = expanded ? 32 : 16; // row height vs dot height
  const chrome = expanded ? 70 : 16; // titlebar+tabs vs padding
  const targetH = Math.max(60, Math.min(chrome + maxItems * itemHeight, 600));
  const [x, y] = win.getPosition();
  const w = win.getSize()[0];
  const currentH = win.getSize()[1];
  if (Math.abs(currentH - targetH) > 10) {
    win.setBounds({ x, y, width: w, height: targetH });
  }
}

// --- IPC: Projects ---
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
  setTimeout(() => sendUpdate(), 2000);
  setTimeout(() => sendUpdate(), 5000);
});

ipcMain.on('projects:focus', (_e, name: string) => {
  focusWindow(name);
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

// --- IPC: Portals ---
ipcMain.on('portals:start', (_e, portalPath: string, startCmd: string) => {
  startPortal(portalPath, startCmd);
  setTimeout(() => sendUpdate(), 3000);
  setTimeout(() => sendUpdate(), 6000);
});

ipcMain.on('portals:stop', (_e, port: number) => {
  stopPortal(port);
  setTimeout(() => sendUpdate(), 1000);
});

ipcMain.handle('portals:getAllEntries', () => {
  return getPortalEntries();
});

ipcMain.on('portals:setVisibility', (_e, name: string, visible: boolean) => {
  const cfg = loadPortalsConfig();
  if (visible) {
    cfg.hidden = cfg.hidden.filter(n => n !== name);
  } else {
    if (!cfg.hidden.includes(name)) cfg.hidden.push(name);
  }
  savePortalsConfig(cfg);
  sendUpdate();
});

ipcMain.on('app:open-url', (_e, url: string) => {
  shell.openExternal(url);
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
