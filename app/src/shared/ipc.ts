// IPC channel names shared between main and renderer

export const IPC = {
  // PTY
  PTY_DATA: 'pty:data',           // main -> renderer (terminal output)
  PTY_INPUT: 'pty:input',         // renderer -> main (keyboard input)
  PTY_RESIZE: 'pty:resize',       // renderer -> main ({cols, rows})

  // Overlay
  OVERLAY_SHOW: 'overlay:show',           // main -> renderer
  OVERLAY_UPDATE: 'overlay:update',       // main -> renderer
  OVERLAY_MESSAGE: 'overlay:message',     // main -> renderer
  OVERLAY_LOADING: 'overlay:loading',     // main -> renderer
  OVERLAY_CLOSE: 'overlay:close',         // main -> renderer
  OVERLAY_KEY: 'overlay:key',             // renderer -> main

  // Status bar
  STATUS_UPDATE: 'status:update',         // main -> renderer

  // Hotkeys
  HOTKEY: 'hotkey',                       // renderer -> main

  // Session
  SESSION_WRITE: 'session:write',         // main -> renderer (send text to Claude PTY)
  SESSION_EXIT: 'session:exit',           // main -> renderer

  // App
  APP_READY: 'app:ready',                 // renderer -> main
  OPEN_URL: 'app:open-url',              // renderer -> main
} as const;

// Serializable overlay item (no functions — actions handled by index in main process)
export interface OverlayItemData {
  label: string;
  value?: string;
  dimmed?: boolean;
  shortcut?: string;
  actionable?: boolean;
  editable?: boolean;
  editValue?: string;
  placeholder?: string;
}

export interface OverlayShowData {
  title: string;
  items: OverlayItemData[];
  footer?: string;
  width?: number;
  selectedIdx: number;
  editing: boolean;
  loading: boolean;
  message?: string;
  anchor?: string;   // element ID to anchor dropdown below (omit for centered modal)
}

export interface StatusBarData {
  claudeActive: boolean;
  projectName: string;
  timeElapsed: string;
  timeRecording: boolean;
  trackerEnabled: boolean;
  trackerTeamKey?: string;
  currentIssueKey?: string;
  currentIssueTitle?: string;
  gitBranch: string;
  gitDirty: boolean;
  lastCommand?: string;
}
