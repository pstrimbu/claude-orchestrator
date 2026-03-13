import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('launcherApi', {
  addProject: () => ipcRenderer.invoke('projects:add'),
  removeProject: (path: string) => ipcRenderer.send('projects:remove', path),
  openProject: (path: string) => ipcRenderer.send('projects:open', path),
  focusProject: (pid: number) => ipcRenderer.send('projects:focus', pid),
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
});
