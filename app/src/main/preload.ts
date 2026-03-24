import { contextBridge, ipcRenderer } from 'electron';

// Inline IPC channel names (can't require local modules in sandboxed preload)
const IPC = {
  PTY_DATA: 'pty:data',
  PTY_INPUT: 'pty:input',
  PTY_RESIZE: 'pty:resize',
  OVERLAY_SHOW: 'overlay:show',
  OVERLAY_CLOSE: 'overlay:close',
  OVERLAY_KEY: 'overlay:key',
  STATUS_UPDATE: 'status:update',
  HOTKEY: 'hotkey',
  SESSION_EXIT: 'session:exit',
  APP_READY: 'app:ready',
  OPEN_URL: 'app:open-url',
};

contextBridge.exposeInMainWorld('orchApi', {
  // Send to main
  sendPtyInput: (data: string) => ipcRenderer.send(IPC.PTY_INPUT, data),
  sendPtyResize: (cols: number, rows: number) => ipcRenderer.send(IPC.PTY_RESIZE, { cols, rows }),
  sendOverlayKey: (key: string, rawBytes?: number[]) => ipcRenderer.send(IPC.OVERLAY_KEY, key, rawBytes),
  sendHotkey: (key: string) => ipcRenderer.send(IPC.HOTKEY, key),
  sendReady: (cols: number, rows: number) => ipcRenderer.send(IPC.APP_READY, { cols, rows }),
  openUrl: (url: string) => ipcRenderer.send(IPC.OPEN_URL, url),

  // Receive from main
  onPtyData: (cb: (data: string) => void) => {
    ipcRenderer.on(IPC.PTY_DATA, (_e, data) => cb(data));
  },
  onOverlayShow: (cb: (data: any) => void) => {
    ipcRenderer.on(IPC.OVERLAY_SHOW, (_e, data) => cb(data));
  },
  onOverlayClose: (cb: () => void) => {
    ipcRenderer.on(IPC.OVERLAY_CLOSE, () => cb());
  },
  onStatusUpdate: (cb: (data: any) => void) => {
    ipcRenderer.on(IPC.STATUS_UPDATE, (_e, data) => cb(data));
  },
  onSessionExit: (cb: (code: number) => void) => {
    ipcRenderer.on(IPC.SESSION_EXIT, (_e, code) => cb(code));
  },
});
