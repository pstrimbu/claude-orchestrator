import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('launcherApi', {
  // Projects
  addProject: () => ipcRenderer.invoke('projects:add'),
  removeProject: (path: string) => ipcRenderer.send('projects:remove', path),
  openProject: (path: string) => ipcRenderer.send('projects:open', path),
  focusProject: (name: string, pid: number) => ipcRenderer.send('projects:focus', name, pid),
  stopProject: (pid: number) => ipcRenderer.send('projects:stop', pid),
  reorderProjects: (paths: string[]) => ipcRenderer.send('projects:reorder', paths),
  cascadeWindows: () => ipcRenderer.send('projects:cascade'),
  expand: () => ipcRenderer.send('window:expand'),
  collapse: () => ipcRenderer.send('window:collapse'),
  onUpdate: (cb: (statuses: any[]) => void) => {
    ipcRenderer.on('projects:update', (_e, data) => cb(data));
  },
  onExpanded: (cb: (expanded: boolean) => void) => {
    ipcRenderer.on('expanded', (_e, val) => cb(val));
  },

  // Portals
  startPortal: (path: string, startCmd: string) => ipcRenderer.send('portals:start', path, startCmd),
  stopPortal: (port: number) => ipcRenderer.send('portals:stop', port),
  getAllPortalEntries: () => ipcRenderer.invoke('portals:getAllEntries'),
  setPortalVisibility: (name: string, visible: boolean) => ipcRenderer.send('portals:setVisibility', name, visible),
  openUrl: (url: string) => ipcRenderer.send('app:open-url', url),
  onPortalsUpdate: (cb: (statuses: any[]) => void) => {
    ipcRenderer.on('portals:update', (_e, data) => cb(data));
  },
});
