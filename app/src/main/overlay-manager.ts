import { BrowserWindow } from 'electron';
import { IPC } from '../shared/ipc';
import type { OverlayItemData, OverlayShowData } from '../shared/ipc';

export interface OverlayItem {
  label: string;
  value?: string;
  action?: () => void | Promise<void>;
  dimmed?: boolean;
  shortcut?: string;
  editable?: boolean;
  editValue?: string;
  placeholder?: string;
  onEdit?: (value: string) => void;
}

export interface OverlayConfig {
  title: string;
  items: OverlayItem[];
  onClose: () => void;
  width?: number;
  footer?: string;
}

export class OverlayManager {
  private _active: OverlayConfig | null = null;
  private _selectedIdx = 0;
  private _loading = false;
  private _message: string | null = null;
  private _editing = false;

  constructor(private win: BrowserWindow) {}

  get active(): boolean {
    return this._active !== null;
  }

  show(config: OverlayConfig): void {
    this._active = config;
    this._selectedIdx = 0;
    this._loading = false;
    this._message = null;
    this._editing = false;
    this.sendState();
  }

  close(): void {
    if (!this._active) return;
    const onClose = this._active.onClose;
    this._active = null;
    this._selectedIdx = 0;
    this._editing = false;
    this.win.webContents.send(IPC.OVERLAY_CLOSE);
    onClose();
  }

  showMessage(msg: string, duration = 2000): void {
    this._message = msg;
    this.sendState();
    setTimeout(() => {
      this._message = null;
      if (this._active) this.sendState();
    }, duration);
  }

  setLoading(loading: boolean): void {
    this._loading = loading;
    if (this._active) this.sendState();
  }

  updateItems(items: OverlayItem[]): void {
    if (!this._active) return;
    this._active.items = items;
    this._editing = false;
    if (this._selectedIdx >= items.length) this._selectedIdx = Math.max(0, items.length - 1);
    this.sendState();
  }

  handleKey(key: string, rawBytes?: number[]): void {
    if (!this._active) return;

    if (this._editing) {
      this.handleEditKey(key, rawBytes);
      return;
    }

    // Handle click events from renderer
    if (key.startsWith('click:')) {
      const idx = parseInt(key.slice(6), 10);
      if (!isNaN(idx) && this._active && idx >= 0 && idx < this._active.items.length) {
        this._selectedIdx = idx;
        const item = this._active.items[idx];
        if (item?.editable) {
          this._editing = true;
          this.sendState();
        } else if (item?.action) {
          this.invokeAction(item.action);
        }
      }
      return;
    }

    switch (key) {
      case 'escape':
        this.close();
        return;
      case 'up':
        this._selectedIdx = Math.max(0, this._selectedIdx - 1);
        this.sendState();
        return;
      case 'down':
        this._selectedIdx = Math.min(this._active.items.length - 1, this._selectedIdx + 1);
        this.sendState();
        return;
      case 'return': {
        const item = this._active.items[this._selectedIdx];
        if (!item) return;
        if (item.editable) {
          this._editing = true;
          this.sendState();
          return;
        }
        if (item.action) {
          this.invokeAction(item.action);
        }
        return;
      }
      default: {
        if (key.length === 1 && this._active) {
          const match = this._active.items.find(
            (item) => item.shortcut?.toLowerCase() === key.toLowerCase() && item.action,
          );
          if (match) {
            this.invokeAction(match.action!);
          }
        }
        return;
      }
    }
  }

  private handleEditKey(key: string, rawBytes?: number[]): void {
    const item = this._active?.items[this._selectedIdx];
    if (!item?.editable) {
      this._editing = false;
      return;
    }

    const current = item.editValue || '';

    switch (key) {
      case 'return':
      case 'escape':
        this._editing = false;
        this.sendState();
        return;
      case 'backspace':
        item.editValue = current.slice(0, -1);
        item.onEdit?.(item.editValue);
        this.sendState();
        return;
      case 'up':
      case 'down':
        this._editing = false;
        if (key === 'up') this._selectedIdx = Math.max(0, this._selectedIdx - 1);
        else this._selectedIdx = Math.min(this._active!.items.length - 1, this._selectedIdx + 1);
        this.sendState();
        return;
      default:
        if (key.length === 1 && rawBytes && rawBytes.length === 1 && rawBytes[0]! >= 32) {
          item.editValue = current + key;
          item.onEdit?.(item.editValue);
          this.sendState();
        }
        return;
    }
  }

  private invokeAction(action: () => void | Promise<void>): void {
    const result = action();
    if (result instanceof Promise) {
      this.setLoading(true);
      result
        .then(() => this.setLoading(false))
        .catch((e) => {
          this.setLoading(false);
          this.showMessage(`Error: ${e.message}`);
        });
    }
  }

  private sendState(): void {
    if (!this._active) return;

    const data: OverlayShowData = {
      title: this._active.title,
      items: this._active.items.map((item): OverlayItemData => ({
        label: item.label,
        value: item.value,
        dimmed: item.dimmed,
        shortcut: item.shortcut,
        actionable: !!item.action,
        editable: item.editable,
        editValue: item.editValue,
        placeholder: item.placeholder,
      })),
      footer: this._active.footer,
      width: this._active.width,
      selectedIdx: this._selectedIdx,
      editing: this._editing,
      loading: this._loading,
      message: this._message || undefined,
    };

    this.win.webContents.send(IPC.OVERLAY_SHOW, data);
  }
}
