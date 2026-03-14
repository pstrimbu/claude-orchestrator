import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebLinksAddon } from '@xterm/addon-web-links';
import type { OverlayShowData, StatusBarData } from '../shared/ipc';

// Exposed via preload
declare global {
  interface Window {
    orchApi: {
      sendPtyInput: (data: string) => void;
      sendPtyResize: (cols: number, rows: number) => void;
      sendOverlayKey: (key: string, rawBytes?: number[]) => void;
      sendHotkey: (key: string) => void;
      sendReady: (cols: number, rows: number) => void;
      onPtyData: (cb: (data: string) => void) => void;
      onOverlayShow: (cb: (data: OverlayShowData) => void) => void;
      onOverlayClose: (cb: () => void) => void;
      onStatusUpdate: (cb: (data: StatusBarData) => void) => void;
      onSessionExit: (cb: (code: number) => void) => void;
    };
  }
}

const api = window.orchApi;
console.log('[renderer] starting, api available:', !!api);

// --- Terminal setup ---
const term = new Terminal({
  fontFamily: "'Menlo', 'Monaco', 'Courier New', monospace",
  fontSize: 13,
  theme: {
    background: '#1e1e1e',
    foreground: '#cccccc',
    cursor: '#cccccc',
    selectionBackground: '#264f78',
  },
  cursorBlink: true,
  scrollback: 10000,
  allowProposedApi: true,
});

const fitAddon = new FitAddon();
term.loadAddon(fitAddon);
term.loadAddon(new WebLinksAddon((_e, url) => {
  api.openUrl(url);
}));

const container = document.getElementById('terminal-container')!;
term.open(container);

// --- Wire PTY <-> xterm ---
term.onData((data) => {
  if (overlayVisible) {
    handleOverlayInput(data);
    return;
  }
  if (handleHotkey(data)) return;
  api.sendPtyInput(data);
});

api.onPtyData((data) => {
  term.write(data);
});

// --- Resize ---
let lastContainerWidth = 0;
let lastContainerHeight = 0;
let resizeTimer: number | null = null;

function doFit(): void {
  const w = container.clientWidth;
  const h = container.clientHeight;
  if (w === lastContainerWidth && h === lastContainerHeight) return;
  lastContainerWidth = w;
  lastContainerHeight = h;

  const wasAtBottom = term.buffer.active.viewportY >= term.buffer.active.baseY;
  fitAddon.fit();
  if (wasAtBottom) term.scrollToBottom();
  if (term.cols > 0 && term.rows > 0) {
    api.sendPtyResize(term.cols, term.rows);
  }
}

// Debounce resize to avoid scroll jumps during rapid output
const resizeObserver = new ResizeObserver(() => {
  if (resizeTimer) clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(() => doFit(), 100);
});
resizeObserver.observe(container);

// --- Hotkeys ---
function handleHotkey(data: string): boolean {
  // F1: \x1bOP
  if (data === '\x1bOP') {
    api.sendHotkey('f1');
    return true;
  }
  // F5: \x1b[15~
  if (data === '\x1b[15~') {
    api.sendHotkey('f5');
    return true;
  }
  // Ctrl+R: \x12
  if (data === '\x12') {
    api.sendHotkey('ctrl+r');
    return true;
  }
  return false;
}

// --- Overlay ---
let overlayVisible = false;
const backdrop = document.getElementById('overlay-backdrop')!;
const panel = document.getElementById('overlay-panel')!;

function handleOverlayInput(data: string): void {
  let key = '';
  const bytes = Array.from(new TextEncoder().encode(data));

  if (data === '\x1b' || data === '\x1b\x1b') key = 'escape';
  else if (data === '\r') key = 'return';
  else if (data === '\x7f') key = 'backspace';
  else if (data === '\x1b[A') key = 'up';
  else if (data === '\x1b[B') key = 'down';
  else if (data.length === 1 && data.charCodeAt(0) >= 32) key = data;
  else key = data;

  api.sendOverlayKey(key, bytes);
}

api.onOverlayShow((data: OverlayShowData) => {
  overlayVisible = true;
  backdrop.classList.remove('hidden');
  panel.classList.remove('hidden');
  renderOverlay(data);
});

api.onOverlayClose(() => {
  overlayVisible = false;
  backdrop.classList.add('hidden');
  panel.classList.add('hidden');
  term.focus();
});

backdrop.addEventListener('click', () => {
  api.sendOverlayKey('escape');
});

function renderOverlay(data: OverlayShowData): void {
  const { title, items, footer, selectedIdx, editing, loading, message } = data;

  let html = `<div class="overlay-title">${escHtml(title)}</div>`;

  if (loading) {
    html += `<div class="overlay-loading">Loading...</div>`;
  }
  if (message) {
    html += `<div class="overlay-message">${escHtml(message)}</div>`;
  }

  html += `<div class="overlay-items">`;

  for (let i = 0; i < items.length; i++) {
    const item = items[i]!;

    if (!item.label && !item.value) {
      html += `<div class="overlay-item empty"></div>`;
      continue;
    }

    const selected = i === selectedIdx;
    const classes = ['overlay-item'];
    if (selected) classes.push('selected');
    if (item.dimmed && !item.actionable) classes.push('dimmed');

    html += `<div class="${classes.join(' ')}" data-idx="${i}">`;

    if (item.editable) {
      const isEditing = selected && editing;
      const val = item.editValue || '';
      const displayHtml = val
        ? escHtml(val)
        : `<span style="color:var(--dim)">${escHtml(item.placeholder || '')}</span>`;
      const cursor = isEditing ? '<span class="edit-cursor">\u2588</span>' : '';
      const fieldClass = isEditing ? 'edit-field editing' : 'edit-field';
      html += `<span class="item-label">${escHtml(item.label)}</span>`;
      html += `<span class="${fieldClass}">${displayHtml}${cursor}</span>`;
    } else {
      html += `<span class="item-label">${escHtml(item.label)}</span>`;
      if (item.value) {
        html += `<span class="item-value">${escHtml(item.value)}</span>`;
      }
    }

    html += `</div>`;
  }

  html += `</div>`;

  if (footer) {
    html += `<div class="overlay-footer">${escHtml(footer)}</div>`;
  }

  panel.innerHTML = html;

  const selectedEl = panel.querySelector('.overlay-item.selected');
  if (selectedEl) selectedEl.scrollIntoView({ block: 'nearest' });

  panel.querySelectorAll('.overlay-item[data-idx]').forEach((el) => {
    el.addEventListener('click', () => {
      const idx = parseInt(el.getAttribute('data-idx')!, 10);
      api.sendOverlayKey('click:' + idx);
    });
  });
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// --- Status bar ---
api.onStatusUpdate((data: StatusBarData) => {
  const claudeDot = document.getElementById('claude-dot')!;
  claudeDot.className = `claude-dot ${data.claudeActive ? 'active' : 'idle'}`;

  document.getElementById('status-project-name')!.textContent = data.projectName;
  document.title = `orch3 - ${data.projectName}`;
  document.getElementById('status-time-value')!.textContent = data.timeElapsed;

  const indicator = document.getElementById('status-time-indicator')!;
  if (data.timeRecording) {
    indicator.textContent = '\u25cf';
    indicator.className = 'status-indicator recording';
  } else {
    indicator.textContent = '\u25cb';
    indicator.className = 'status-indicator stopped';
  }

  const issuesEl = document.getElementById('status-issues-value')!;
  if (data.currentIssueKey) {
    issuesEl.textContent = data.currentIssueKey;
  } else if (data.trackerEnabled) {
    issuesEl.textContent = data.trackerTeamKey || 'Issues';
  } else {
    issuesEl.textContent = 'No tracker';
  }

  const gitEl = document.getElementById('status-git-value')!;
  if (data.gitBranch) {
    gitEl.textContent = `${data.gitBranch}${data.gitDirty ? '*' : ''}`;
  } else {
    gitEl.textContent = '\u2014';
  }

  const cmdEl = document.getElementById('status-command')!;
  if (data.lastCommand) {
    cmdEl.textContent = data.lastCommand;
    cmdEl.title = data.lastCommand;
  }
});

// Status bar click opens menu
document.getElementById('status-bar')!.addEventListener('click', () => {
  api.sendHotkey('f1');
});

// Session exit
api.onSessionExit((code) => {
  term.write(`\r\n\x1b[90m[Session exited with code ${code}]\x1b[0m\r\n`);
});

// --- Tell main we're ready after layout settles ---
requestAnimationFrame(() => {
  fitAddon.fit();
  console.log('[renderer] terminal size:', term.cols, 'x', term.rows);
  api.sendReady(term.cols, term.rows);
  term.focus();
});
