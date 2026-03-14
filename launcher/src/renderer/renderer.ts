interface ProjectStatus {
  path: string;
  name: string;
  running: boolean;
  pid: number | null;
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

interface PortalEntry {
  name: string;
  uiPort: number;
  apiPort: number;
  path: string;
  visible: boolean;
}

declare global {
  interface Window {
    launcherApi: {
      addProject: () => void;
      removeProject: (path: string) => void;
      openProject: (path: string) => void;
      focusProject: (name: string) => void;
      stopProject: (pid: number) => void;
      reorderProjects: (paths: string[]) => void;
      cascadeWindows: () => void;
      expand: () => void;
      collapse: () => void;
      onUpdate: (cb: (statuses: ProjectStatus[]) => void) => void;
      onExpanded: (cb: (expanded: boolean) => void) => void;
      startPortal: (path: string, startCmd: string) => void;
      stopPortal: (port: number) => void;
      openUrl: (url: string) => void;
      getAllPortalEntries: () => Promise<PortalEntry[]>;
      setPortalVisibility: (name: string, visible: boolean) => void;
      onPortalsUpdate: (cb: (statuses: PortalStatus[]) => void) => void;
    };
  }
}

const api = window.launcherApi;
const listEl = document.getElementById('project-list')!;
const portalListEl = document.getElementById('portal-list')!;
const addBtn = document.getElementById('add-btn')!;
const cascadeBtn = document.getElementById('cascade-btn')!;
const collapsedView = document.getElementById('collapsed-view')!;
const dotStrip = document.getElementById('dot-strip')!;
const dotStripPortals = document.getElementById('dot-strip-portals')!;

addBtn.addEventListener('click', () => api.addProject());
cascadeBtn.addEventListener('click', () => api.cascadeWindows());

// --- Tabs ---
let activeTab = 'projects';
let showingPortalConfig = false;

document.querySelectorAll('#tab-bar .tab').forEach(tab => {
  tab.addEventListener('click', () => {
    const tabName = (tab as HTMLElement).dataset.tab!;
    activeTab = tabName;
    showingPortalConfig = false;
    document.querySelectorAll('#tab-bar .tab').forEach(t => t.classList.remove('active'));
    tab.classList.add('active');
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
    document.getElementById(tabName === 'projects' ? 'project-list' : 'portal-list')!.classList.add('active');

    // Show/hide project-specific titlebar actions
    addBtn.style.display = tabName === 'projects' ? '' : 'none';
    cascadeBtn.style.display = tabName === 'projects' ? '' : 'none';
  });
});

// Hover to expand, leave to collapse
let collapseTimer: number | null = null;

collapsedView.addEventListener('mouseenter', () => {
  if (collapseTimer) { clearTimeout(collapseTimer); collapseTimer = null; }
  api.expand();
});

document.body.addEventListener('mouseleave', () => {
  if (!document.body.classList.contains('expanded')) return;
  collapseTimer = window.setTimeout(() => api.collapse(), 400);
});

document.body.addEventListener('mouseenter', () => {
  if (collapseTimer) { clearTimeout(collapseTimer); collapseTimer = null; }
});

api.onExpanded((expanded) => {
  document.body.classList.toggle('expanded', expanded);
  document.body.classList.toggle('collapsed', !expanded);
});

let currentStatuses: ProjectStatus[] = [];
let dragSrcIdx: number | null = null;

api.onUpdate((statuses) => {
  currentStatuses = statuses;
  renderDots(statuses);
  render(statuses);

});

api.onPortalsUpdate((statuses) => {
  renderPortalDots(statuses);
  if (!showingPortalConfig) {
    renderPortals(statuses);
  
  }
});

function renderDots(statuses: ProjectStatus[]): void {
  dotStrip.innerHTML = '';
  statuses.forEach((s) => {
    const dot = document.createElement('div');
    dot.className = `strip-dot ${s.running ? 'running' : 'stopped'}`;
    dot.title = s.name;
    dotStrip.appendChild(dot);
  });
}

function renderPortalDots(statuses: PortalStatus[]): void {
  dotStripPortals.innerHTML = '';
  statuses.forEach((s) => {
    const running = s.uiRunning || s.apiRunning;
    const dot = document.createElement('div');
    dot.className = `strip-dot ${running ? 'running' : 'stopped'}`;
    dot.title = s.name;
    dotStripPortals.appendChild(dot);
  });
}

// --- Portal rendering ---
function renderPortals(statuses: PortalStatus[]): void {
  portalListEl.innerHTML = '';

  if (statuses.length === 0) {
    portalListEl.innerHTML = '<div class="empty">No visible portals<br><button class="btn btn-config" id="portal-config-btn">Configure</button></div>';
    document.getElementById('portal-config-btn')?.addEventListener('click', showPortalConfig);
    return;
  }

  // Config button at top
  const configRow = document.createElement('div');
  configRow.className = 'portal-config-row';
  configRow.innerHTML = '<button class="btn btn-config" id="portal-config-btn">Configure visible portals</button>';
  portalListEl.appendChild(configRow);
  document.getElementById('portal-config-btn')!.addEventListener('click', showPortalConfig);

  statuses.forEach((s) => {
    const row = document.createElement('div');
    row.className = 'portal-row';

    const running = s.uiRunning || s.apiRunning;
    const dot = running ? '<span class="dot running"></span>' : '<span class="dot stopped"></span>';

    let portInfo = '';
    if (s.uiRunning) portInfo += `<span class="port-badge running clickable" data-action="open-port" data-port="${s.uiPort}" title="Open in browser">UI:${s.uiPort}</span>`;
    else portInfo += `<span class="port-badge stopped">UI:${s.uiPort}</span>`;
    if (s.apiRunning) portInfo += `<span class="port-badge running">API:${s.apiPort}</span>`;
    else portInfo += `<span class="port-badge stopped">API:${s.apiPort}</span>`;

    const btn = running
      ? `<button class="btn btn-stop" data-action="stop-portal" data-ui-port="${s.uiPort}" data-api-port="${s.apiPort}" title="Stop">Stop</button>`
      : `<button class="btn btn-open" data-action="start-portal" data-path="${escAttr(s.path)}" data-start-cmd="${escAttr(s.startCmd)}" title="${escAttr(s.startCmd)}">Start</button>`;

    row.innerHTML = `
      <div class="portal-info">
        ${dot}
        <span class="portal-name">${escHtml(s.name)}</span>
        <div class="port-badges">${portInfo}</div>
      </div>
      <div class="portal-actions">${btn}</div>
    `;

    row.querySelectorAll('.port-badge.clickable').forEach(badge => {
      badge.addEventListener('click', (e) => {
        e.stopPropagation();
        const port = (badge as HTMLElement).dataset.port;
        api.openUrl(`http://localhost:${port}`);
      });
    });

    row.querySelectorAll('button').forEach(b => {
      b.addEventListener('click', (e) => {
        e.stopPropagation();
        const action = (b as HTMLElement).dataset.action;
        if (action === 'open-port') {
          const port = (b as HTMLElement).dataset.port;
          api.openUrl(`http://localhost:${port}`);
        } else if (action === 'start-portal') {
          api.startPortal((b as HTMLElement).dataset.path!, (b as HTMLElement).dataset.startCmd!);
          (b as HTMLElement).textContent = 'Starting...';
          (b as HTMLElement).classList.add('disabled');
        } else if (action === 'stop-portal') {
          const uiPort = Number((b as HTMLElement).dataset.uiPort);
          const apiPort = Number((b as HTMLElement).dataset.apiPort);
          api.stopPortal(uiPort);
          api.stopPortal(apiPort);
          (b as HTMLElement).textContent = 'Stopping...';
          (b as HTMLElement).classList.add('disabled');
        }
      });
    });

    portalListEl.appendChild(row);
  });
}

async function showPortalConfig(): Promise<void> {
  showingPortalConfig = true;
  const entries: PortalEntry[] = await api.getAllPortalEntries();
  portalListEl.innerHTML = '';

  const header = document.createElement('div');
  header.className = 'portal-config-row';
  header.innerHTML = '<button class="btn btn-config" id="portal-config-done">Done</button>';
  portalListEl.appendChild(header);
  document.getElementById('portal-config-done')!.addEventListener('click', () => {
    showingPortalConfig = false;
  });

  entries.forEach(entry => {
    const row = document.createElement('div');
    row.className = 'portal-row config-row';
    row.innerHTML = `
      <label class="portal-toggle">
        <input type="checkbox" ${entry.visible ? 'checked' : ''} data-name="${escAttr(entry.name)}">
        <span class="portal-name">${escHtml(entry.name)}</span>
      </label>
    `;
    const checkbox = row.querySelector('input')! as HTMLInputElement;
    checkbox.addEventListener('change', () => {
      api.setPortalVisibility(entry.name, checkbox.checked);
    });
    portalListEl.appendChild(row);
  });
}

// --- Project rendering ---
function render(statuses: ProjectStatus[]): void {
  listEl.innerHTML = '';

  if (statuses.length === 0) {
    listEl.innerHTML = '<div class="empty">Click + to add a project</div>';
    return;
  }

  statuses.forEach((s, idx) => {
    const row = document.createElement('div');
    row.className = 'project-row';
    row.draggable = true;
    row.dataset.idx = String(idx);
    row.dataset.path = s.path;

    const dot = s.running ? '<span class="dot running"></span>' : '<span class="dot stopped"></span>';
    const name = escHtml(s.name);

    let buttons = '';
    if (s.running && s.pid) {
      buttons = `
        <button class="btn btn-focus" data-action="focus" data-name="${escAttr(s.name)}" data-pid="${s.pid}" title="Bring to front">Focus</button>
        <button class="btn btn-stop" data-action="stop" data-pid="${s.pid}" title="Stop orch3">Stop</button>
      `;
    } else {
      buttons = `
        <button class="btn btn-open" data-action="open" data-path="${escAttr(s.path)}" title="Launch orch3">Open</button>
      `;
    }

    row.innerHTML = `
      <div class="project-info">
        ${dot}
        <span class="project-name">${name}</span>
      </div>
      <div class="project-actions">
        ${buttons}
        <button class="btn btn-remove" data-action="remove" data-path="${escAttr(s.path)}" title="Remove from list">&times;</button>
      </div>
    `;

    row.querySelectorAll('button').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const action = (btn as HTMLElement).dataset.action;
        switch (action) {
          case 'focus':
            api.focusProject((btn as HTMLElement).dataset.name!, Number((btn as HTMLElement).dataset.pid));
            break;
          case 'stop':
            api.stopProject(Number((btn as HTMLElement).dataset.pid));
            break;
          case 'open':
            api.openProject((btn as HTMLElement).dataset.path!);
            (btn as HTMLElement).textContent = 'Starting...';
            (btn as HTMLElement).classList.add('disabled');
            break;
          case 'remove':
            api.removeProject((btn as HTMLElement).dataset.path!);
            break;
        }
      });
    });

    // Drag-and-drop reorder
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

      const paths = currentStatuses.map((s) => s.path);
      const [moved] = paths.splice(dragSrcIdx, 1);
      paths.splice(idx, 0, moved!);
      api.reorderProjects(paths);
    });

    listEl.appendChild(row);
  });
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}
