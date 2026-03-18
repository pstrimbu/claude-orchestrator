import { drawBox, style, colors, cursor, keyName } from './ansi.js';
import type { Screen } from './screen.js';

export interface OverlayItem {
  label: string;
  value?: string;
  action?: () => void | Promise<void>;
  dimmed?: boolean;
  shortcut?: string;
  // Editable text field: when selected, typing modifies the value
  editable?: boolean;
  editValue?: string;       // current text being edited
  placeholder?: string;     // shown when editValue is empty
  onEdit?: (value: string) => void; // called on each keystroke
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

  constructor(private screen: Screen) {}

  get active(): boolean {
    return this._active !== null;
  }

  show(config: OverlayConfig): void {
    this._active = config;
    this._selectedIdx = 0;
    this._loading = false;
    this._message = null;
    this._editing = false;
    this.render();
  }

  close(): void {
    if (!this._active) return;
    const onClose = this._active.onClose;
    this._active = null;
    this._selectedIdx = 0;
    this._editing = false;
    this.screen.clearOverlay();
    onClose();
  }

  showMessage(msg: string, duration = 2000): void {
    this._message = msg;
    this.render();
    setTimeout(() => {
      this._message = null;
      if (this._active) this.render();
    }, duration);
  }

  setLoading(loading: boolean): void {
    this._loading = loading;
    if (this._active) this.render();
  }

  updateItems(items: OverlayItem[]): void {
    if (!this._active) return;
    this._active.items = items;
    this._editing = false;
    if (this._selectedIdx >= items.length) this._selectedIdx = Math.max(0, items.length - 1);
    this.render();
  }

  handleKey(data: Buffer): boolean {
    if (!this._active) return false;
    const key = keyName(data);

    // If editing a text field, handle typing
    if (this._editing) {
      return this.handleEditKey(key, data);
    }

    switch (key) {
      case 'escape':
        this.close();
        return true;
      case 'up':
        this._selectedIdx = Math.max(0, this._selectedIdx - 1);
        this.render();
        return true;
      case 'down':
        this._selectedIdx = Math.min(this._active.items.length - 1, this._selectedIdx + 1);
        this.render();
        return true;
      case 'return': {
        const item = this._active.items[this._selectedIdx];
        if (!item) return true;

        if (item.editable) {
          this._editing = true;
          this.render();
          return true;
        }

        if (item.action) {
          const result = item.action();
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
        return true;
      }
      default: {
        // Check for single-letter shortcut keys
        if (key.length === 1 && this._active) {
          const match = this._active.items.find(
            (item) => item.shortcut?.toLowerCase() === key.toLowerCase() && item.action,
          );
          if (match) {
            const result = match.action!();
            if (result instanceof Promise) {
              this.setLoading(true);
              result
                .then(() => this.setLoading(false))
                .catch((e) => {
                  this.setLoading(false);
                  this.showMessage(`Error: ${e.message}`);
                });
            }
            return true;
          }
        }
        return false;
      }
    }
  }

  private handleEditKey(key: string, data: Buffer): boolean {
    const item = this._active?.items[this._selectedIdx];
    if (!item?.editable) {
      this._editing = false;
      return false;
    }

    const current = item.editValue || '';

    switch (key) {
      case 'return':
      case 'escape':
        this._editing = false;
        this.render();
        return true;
      case 'backspace':
        item.editValue = current.slice(0, -1);
        item.onEdit?.(item.editValue);
        this.render();
        return true;
      case 'up':
      case 'down':
        this._editing = false;
        if (key === 'up') this._selectedIdx = Math.max(0, this._selectedIdx - 1);
        else this._selectedIdx = Math.min(this._active!.items.length - 1, this._selectedIdx + 1);
        this.render();
        return true;
      default:
        if (key.length === 1 && data.length === 1 && data[0]! >= 32) {
          item.editValue = current + key;
          item.onEdit?.(item.editValue);
          this.render();
          return true;
        }
        return true;
    }
  }

  handleMouse(_col: number, _row: number, _pressed: boolean): boolean {
    return false;
  }

  private render(): void {
    if (!this._active) return;

    const { title, items, footer } = this._active;
    const width = this._active.width || Math.min(60, this.screen.cols - 4);
    const maxItems = this.screen.rows - 8;
    const visibleItems = items.slice(0, maxItems);
    const height = visibleItems.length + 4 + (footer ? 2 : 0) + (this._message ? 1 : 0);

    const startCol = Math.floor((this.screen.cols - width) / 2);
    const startRow = 2;

    const lines: string[] = [];

    lines.push('');

    if (this._loading) {
      lines.push(`  ${colors.overlayFg}Loading...${style.reset}`);
    }

    if (this._message) {
      lines.push(`  ${colors.warnFg}${this._message}${style.reset}`);
    }

    for (let i = 0; i < visibleItems.length; i++) {
      const item = visibleItems[i]!;
      const selected = i === this._selectedIdx;

      if (item.editable) {
        const editing = selected && this._editing;
        const val = item.editValue || '';
        const display = val || (item.placeholder ? `${colors.dimFg}${item.placeholder}${style.reset}` : '');
        const cursorChar = editing ? `${colors.accentFg}\u2588${style.reset}` : '';
        const fieldBg = editing ? style.underline : '';
        const prefix = selected ? `${colors.accentFg}\u25b6 ` : '  ';
        const labelColor = selected ? colors.accentFg : colors.overlayFg;
        lines.push(`${prefix}${labelColor}${item.label}${style.reset} ${fieldBg}${display}${cursorChar}${style.reset}`);
      } else {
        const prefix = selected ? `${colors.accentFg}\u25b6 ` : '  ';
        const labelStyle = item.dimmed ? colors.dimFg : selected ? colors.accentFg : colors.overlayFg;
        let line = `${prefix}${labelStyle}${item.label}${style.reset}`;
        if (item.value) {
          line += `${colors.dimFg} ${item.value}${style.reset}`;
        }
        lines.push(line);
      }
    }

    if (items.length > maxItems) {
      lines.push(`  ${colors.dimFg}... and ${items.length - maxItems} more${style.reset}`);
    }

    lines.push('');
    if (footer) {
      lines.push(`  ${colors.hotkey}${footer}${style.reset}`);
    }
    lines.push(`  ${colors.hotkey}[Esc] Close  [\u2191\u2193] Navigate  [Enter] Select${style.reset}`);

    const box = drawBox(startRow, startCol, width, height, title, lines, true);

    // First render switches to alt screen, subsequent renders update in place
    if (!this.screen.overlayActive) {
      this.screen.renderOverlay(box);
    } else {
      this.screen.updateOverlay(box);
    }
  }
}
