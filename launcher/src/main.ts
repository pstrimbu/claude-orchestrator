import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { homeDir } from '@tauri-apps/api/path';
import { open } from '@tauri-apps/plugin-dialog';
import { open as shellOpen } from '@tauri-apps/plugin-shell';

interface AppStatus {
  name: string;
  sessionPath: string | null;
  sessionRunning: boolean;
  sessionPid: number | null;
  portalName: string | null;
  uiPort: number | null;
  apiPort: number | null;
  portalPath: string | null;
  portalStartCmd: string | null;
  uiRunning: boolean;
  apiRunning: boolean;
}

interface PortalEntry {
  name: string;
  uiPort: number;
  apiPort: number;
  path: string;
  visible: boolean;
}

const listEl = document.getElementById('app-list')!;
const addBtn = document.getElementById('add-btn')!;
const cascadeBtn = document.getElementById('cascade-btn')!;
const addPortalBtn = document.getElementById('add-portal-btn')!;
const dotStrip = document.getElementById('dot-strip')!;

// --- Add project via native dialog ---
addBtn.addEventListener('click', async () => {
  const home = await homeDir();
  const dir = await open({
    directory: true,
    multiple: false,
    defaultPath: `${home}/dev`,
  });
  if (dir) {
    await invoke('add_project', { path: dir });
  }
});

cascadeBtn.addEventListener('click', () => invoke('cascade_windows'));

// Hover expand/collapse is handled natively by Rust via CoreGraphics mouse polling
// (macOS WebViews don't receive mouse events when the window is unfocused)

// --- Listen for backend events ---
let currentApps: AppStatus[] = [];
let dragSrcIdx: number | null = null;
let showingAddPortal = false;

listen<AppStatus[]>('apps-update', (event) => {
  currentApps = event.payload;
  renderDots(currentApps);
  render(currentApps);
});

listen<boolean>('expanded', (event) => {
  document.body.classList.toggle('expanded', event.payload);
  document.body.classList.toggle('collapsed', !event.payload);
});

// Signal the backend to show the window once CSS has painted
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    invoke('show_window');
  });
});

// --- Dot strip (collapsed view) ---
function renderDots(apps: AppStatus[]): void {
  dotStrip.innerHTML = '';
  apps.forEach((a) => {
    const hasSession = a.sessionPath !== null;
    const hasPortal = a.portalName !== null;
    const portalRunning = a.uiRunning || a.apiRunning;

    if (hasSession && hasPortal) {
      const wrapper = document.createElement('div');
      wrapper.className = 'dot-pair';
      wrapper.title = a.name;
      const sDot = document.createElement('div');
      sDot.className = `strip-dot-half ${a.sessionRunning ? 'running' : 'stopped'}`;
      const pDot = document.createElement('div');
      pDot.className = `strip-dot-half ${portalRunning ? 'running' : 'stopped'}`;
      wrapper.appendChild(sDot);
      wrapper.appendChild(pDot);
      dotStrip.appendChild(wrapper);
    } else {
      const dot = document.createElement('div');
      dot.className = `strip-dot ${(hasSession ? a.sessionRunning : portalRunning) ? 'running' : 'stopped'}`;
      dot.title = a.name;
      dotStrip.appendChild(dot);
    }
  });
}

// --- Add portal picker ---
addPortalBtn.addEventListener('click', async () => {
  showingAddPortal = true;
  const entries: PortalEntry[] = await invoke('get_all_portal_entries');
  const hidden = entries.filter(e => !e.visible);

  if (hidden.length === 0) {
    showingAddPortal = false;
    return;
  }

  listEl.innerHTML = '';
  hidden.forEach(entry => {
    const row = document.createElement('div');
    row.className = 'app-row';
    row.innerHTML = `
      <div class="app-info">
        <span class="app-name">${escHtml(entry.name)}</span>
      </div>
      <div class="app-actions">
        <button class="btn btn-open">Add</button>
      </div>
    `;
    row.querySelector('button')!.addEventListener('click', () => {
      invoke('set_portal_visibility', { name: entry.name, visible: true });
      showingAddPortal = false;
    });
    listEl.appendChild(row);
  });
});

// --- Expanded list rendering ---
function render(apps: AppStatus[]): void {
  if (showingAddPortal) return;
  listEl.innerHTML = '';

  if (apps.length === 0) {
    listEl.innerHTML = '<div class="empty">Click + to add a project</div>';
    return;
  }

  apps.forEach((a, idx) => {
    const row = document.createElement('div');
    row.className = 'app-row';
    if (a.sessionPath) {
      row.draggable = true;
      row.dataset.idx = String(idx);
      row.dataset.path = a.sessionPath;
    }

    const hasSession = a.sessionPath !== null;
    const hasPortal = a.portalName !== null;
    const portalRunning = a.uiRunning || a.apiRunning;

    // Status dot
    let dotHtml: string;
    if (hasSession) {
      dotHtml = `<span class="dot ${a.sessionRunning ? 'running' : 'stopped'}"></span>`;
    } else {
      dotHtml = `<span class="dot ${portalRunning ? 'running' : 'stopped'}"></span>`;
    }

    // Port badges — fixed columns in app-actions area
    let uiCol = '<span class="btn-placeholder port-col"></span>';
    let apiCol = '<span class="btn-placeholder port-col"></span>';
    if (hasPortal && a.uiPort !== null && a.apiPort !== null) {
      uiCol = a.uiRunning
        ? `<span class="port-badge running clickable" data-port="${a.uiPort}" title="Open in browser">UI:${a.uiPort}</span>`
        : `<span class="port-badge stopped">UI:${a.uiPort}</span>`;
      apiCol = a.apiRunning
        ? `<span class="port-badge running clickable" data-port="${a.apiPort}" title="Open in browser">API:${a.apiPort}</span>`
        : `<span class="port-badge stopped">API:${a.apiPort}</span>`;
    }

    // Action buttons — fixed column slots: [open/focus] [stop/port] [remove]
    // Column 1: Open (not running) or Focus (running)
    // Column 2: Port (portal) or Stop (running session, no portal)
    // When running session + portal: Focus, Stop+Port both in col 2 area
    let openSlot = '';
    let portSlot = '';
    let stopBtn = '';
    let removeBtn = '';

    if (hasSession) {
      if (a.sessionRunning && a.sessionPid) {
        openSlot = `<button class="btn btn-focus" data-action="focus" data-pid="${a.sessionPid}" title="Bring to front">Focus</button>`;
        stopBtn = `<button class="btn btn-stop" data-action="stop-session" data-pid="${a.sessionPid}" title="Stop orch3">Stop</button>`;
      } else {
        openSlot = `<button class="btn btn-open" data-action="open-session" data-path="${escAttr(a.sessionPath!)}" title="Launch orch3">Open</button>`;
      }
    } else if (hasPortal && a.portalPath) {
      openSlot = `<button class="btn btn-open" data-action="open-session" data-path="${escAttr(a.portalPath)}" title="Launch orch3">Open</button>`;
    }
    if (hasPortal && a.portalPath) {
      if (portalRunning) {
        portSlot = `<button class="btn btn-stop" data-action="stop-portal" data-ui-port="${a.uiPort}" data-api-port="${a.apiPort}" title="Stop portal">Port</button>`;
      } else {
        portSlot = `<button class="btn btn-open" data-action="start-portal" data-path="${escAttr(a.portalPath)}" data-start-cmd="${escAttr(a.portalStartCmd!)}" title="${escAttr(a.portalStartCmd!)}">Port</button>`;
      }
    }
    if (hasSession) {
      removeBtn = `<button class="btn btn-remove" data-action="remove" data-path="${escAttr(a.sessionPath!)}" title="Remove from list">&times;</button>`;
    } else if (hasPortal) {
      removeBtn = `<button class="btn btn-remove" data-action="archive-portal" data-name="${escAttr(a.portalName!)}" title="Hide portal">&times;</button>`;
    }

    // Use invisible placeholders to keep columns aligned
    const openCol = openSlot || '<span class="btn-placeholder"></span>';
    const portCol = (stopBtn + portSlot) || '<span class="btn-placeholder"></span>';
    const buttons = uiCol + apiCol + openCol + portCol + removeBtn;

    row.innerHTML = `
      <div class="app-info">
        ${dotHtml}
        <span class="app-name">${escHtml(a.name)}</span>
      </div>
      <div class="app-actions">${buttons}</div>
    `;

    // Port badge clicks
    row.querySelectorAll('.port-badge.clickable').forEach(badge => {
      badge.addEventListener('click', (e) => {
        e.stopPropagation();
        const port = (badge as HTMLElement).dataset.port;
        shellOpen(`http://localhost:${port}`);
      });
    });

    // Button clicks
    row.querySelectorAll('button').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const el = btn as HTMLElement;
        const action = el.dataset.action;
        switch (action) {
          case 'focus':
            invoke('focus_project', { pid: Number(el.dataset.pid) });
            break;
          case 'stop-session':
            invoke('stop_project', { pid: Number(el.dataset.pid) });
            break;
          case 'open-session':
            invoke('open_project', { path: el.dataset.path });
            el.textContent = 'Starting...';
            el.classList.add('disabled');
            break;
          case 'start-portal':
            invoke('start_portal', { path: el.dataset.path, startCmd: el.dataset.startCmd });
            el.textContent = '...';
            el.classList.add('disabled');
            break;
          case 'stop-portal':
            invoke('stop_portal', { port: Number(el.dataset.uiPort) });
            invoke('stop_portal', { port: Number(el.dataset.apiPort) });
            el.textContent = '...';
            el.classList.add('disabled');
            break;
          case 'remove':
            invoke('remove_project', { path: el.dataset.path });
            break;
          case 'archive-portal':
            invoke('set_portal_visibility', { name: el.dataset.name, visible: false });
            break;
        }
      });
    });

    // Drag-and-drop reorder
    if (a.sessionPath) {
      row.addEventListener('dragstart', (e) => {
        dragSrcIdx = idx;
        row.classList.add('dragging');
        e.dataTransfer!.effectAllowed = 'move';
      });

      row.addEventListener('dragend', () => {
        row.classList.remove('dragging');
        dragSrcIdx = null;
        listEl.querySelectorAll('.drag-over').forEach((el) => el.classList.remove('drag-over'));
      });

      row.addEventListener('dragover', (e) => {
        e.preventDefault();
        e.dataTransfer!.dropEffect = 'move';
        row.classList.add('drag-over');
      });

      row.addEventListener('dragleave', () => {
        row.classList.remove('drag-over');
      });

      row.addEventListener('drop', (e) => {
        e.preventDefault();
        row.classList.remove('drag-over');
        if (dragSrcIdx === null || dragSrcIdx === idx) return;
        const paths = currentApps.filter(a => a.sessionPath).map(a => a.sessionPath!);
        const [moved] = paths.splice(dragSrcIdx, 1);
        paths.splice(idx, 0, moved!);
        invoke('reorder_projects', { paths });
      });
    }

    listEl.appendChild(row);
  });
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}
