interface ProjectStatus {
  path: string;
  name: string;
  running: boolean;
  pid: number | null;
}

declare global {
  interface Window {
    launcherApi: {
      addProject: () => void;
      removeProject: (path: string) => void;
      openProject: (path: string) => void;
      focusProject: (pid: number) => void;
      stopProject: (pid: number) => void;
      reorderProjects: (paths: string[]) => void;
      cascadeWindows: () => void;
      expand: () => void;
      collapse: () => void;
      onUpdate: (cb: (statuses: ProjectStatus[]) => void) => void;
      onExpanded: (cb: (expanded: boolean) => void) => void;
    };
  }
}

const api = window.launcherApi;
const listEl = document.getElementById('project-list')!;
const addBtn = document.getElementById('add-btn')!;
const cascadeBtn = document.getElementById('cascade-btn')!;
const collapsedView = document.getElementById('collapsed-view')!;
const dotStrip = document.getElementById('dot-strip')!;

addBtn.addEventListener('click', () => api.addProject());
cascadeBtn.addEventListener('click', () => api.cascadeWindows());

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

function renderDots(statuses: ProjectStatus[]): void {
  dotStrip.innerHTML = '';
  statuses.forEach((s) => {
    const dot = document.createElement('div');
    dot.className = `strip-dot ${s.running ? 'running' : 'stopped'}`;
    dot.title = s.name;
    dotStrip.appendChild(dot);
  });
}

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
        <button class="btn btn-focus" data-action="focus" data-pid="${s.pid}" title="Bring to front">Focus</button>
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
            api.focusProject(Number((btn as HTMLElement).dataset.pid));
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
