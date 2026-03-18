import { cursor, screen as scr, style, colors } from './ansi.js';

export const STATUS_BAR_HEIGHT = 0; // No fixed status bar — info is in terminal title

export class Screen {
  cols: number;
  rows: number;
  private _overlayActive = false;

  constructor() {
    this.cols = process.stdout.columns || 120;
    this.rows = process.stdout.rows || 40;
  }

  setup(): void {
    // Nothing special — standard terminal, no scroll regions, no alternate screen
  }

  cleanup(): void {
    // Reset terminal title
    process.stdout.write('\x1b]0;\x07');
    process.stdout.write(cursor.show);
  }

  resize(): void {
    this.cols = process.stdout.columns || 120;
    this.rows = process.stdout.rows || 40;
  }

  get sessionRows(): number {
    return this.rows;
  }

  get overlayActive(): boolean {
    return this._overlayActive;
  }

  set overlayActive(v: boolean) {
    this._overlayActive = v;
  }

  // Set iTerm tab title via OSC 1 and window title via OSC 2
  setTitle(title: string): void {
    process.stdout.write(`\x1b]0;${title}\x07`);
  }

  writeToSession(data: string): void {
    if (this._overlayActive) return;
    process.stdout.write(data);
  }

  // Overlays use the alternate screen buffer so they don't clobber scrollback
  renderOverlay(content: string): void {
    this._overlayActive = true;
    process.stdout.write(scr.altOn);
    process.stdout.write(scr.clear);
    process.stdout.write(content);
  }

  // Re-render overlay content (stays on alt screen)
  updateOverlay(content: string): void {
    if (!this._overlayActive) return;
    process.stdout.write(scr.clear);
    process.stdout.write(content);
  }

  clearOverlay(): void {
    if (!this._overlayActive) return;
    this._overlayActive = false;
    process.stdout.write(scr.altOff);
  }

  write(data: string): void {
    process.stdout.write(data);
  }
}
