// ANSI escape code helpers for terminal rendering

export const ESC = '\x1b';
export const CSI = `${ESC}[`;

export const cursor = {
  to: (row: number, col: number) => `${CSI}${row};${col}H`,
  save: `${ESC}7`,
  restore: `${ESC}8`,
  hide: `${CSI}?25l`,
  show: `${CSI}?25h`,
  up: (n = 1) => `${CSI}${n}A`,
  down: (n = 1) => `${CSI}${n}B`,
  forward: (n = 1) => `${CSI}${n}C`,
  back: (n = 1) => `${CSI}${n}D`,
};

export const screen = {
  altOn: `${CSI}?1049h`,
  altOff: `${CSI}?1049l`,
  clear: `${CSI}2J`,
  clearLine: `${CSI}2K`,
  clearDown: `${CSI}J`,
  scrollRegion: (top: number, bottom: number) => `${CSI}${top};${bottom}r`,
  resetScroll: `${CSI}r`,
};

export const mouse = {
  enable: `${CSI}?1000h${CSI}?1006h`,
  disable: `${CSI}?1000l${CSI}?1006l`,
};

export const style = {
  reset: `${CSI}0m`,
  bold: `${CSI}1m`,
  dim: `${CSI}2m`,
  italic: `${CSI}3m`,
  underline: `${CSI}4m`,
  inverse: `${CSI}7m`,
  fg256: (n: number) => `${CSI}38;5;${n}m`,
  bg256: (n: number) => `${CSI}48;5;${n}m`,
  fgRgb: (r: number, g: number, b: number) => `${CSI}38;2;${r};${g};${b}m`,
  bgRgb: (r: number, g: number, b: number) => `${CSI}48;2;${r};${g};${b}m`,
};

// Common color presets
export const colors = {
  statusBg: style.bg256(236),     // dark gray
  statusFg: style.fg256(252),     // light gray
  accentFg: style.fg256(75),      // blue
  activeFg: style.fg256(156),     // green
  warnFg: style.fg256(220),       // yellow
  errorFg: style.fg256(203),      // red
  dimFg: style.fg256(249),        // medium gray (readable)
  hotkey: style.fg256(81),        // bright cyan
  separator: style.fg256(240),    // dim gray
  overlayBg: style.bg256(235),    // overlay background
  overlayFg: style.fg256(255),    // overlay text (bright white)
  overlayBorder: style.fg256(245), // overlay border
};

const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;

export function stripAnsi(str: string): string {
  return str.replace(ANSI_RE, '');
}

export function visibleLength(str: string): number {
  return stripAnsi(str).length;
}

export function pad(str: string, width: number): string {
  const vlen = visibleLength(str);
  if (vlen >= width) return str;
  return str + ' '.repeat(width - vlen);
}

export function center(str: string, width: number): string {
  const vlen = visibleLength(str);
  if (vlen >= width) return str;
  const left = Math.floor((width - vlen) / 2);
  return ' '.repeat(left) + str + ' '.repeat(width - vlen - left);
}

// Parse SGR mouse events: \x1b[<button;col;row{M|m}
export interface MouseEvent {
  button: number;   // 0=left, 1=middle, 2=right, 64=scrollUp, 65=scrollDown
  col: number;
  row: number;
  pressed: boolean; // true=press, false=release
}

export function parseMouseEvent(data: string): MouseEvent | null {
  const match = data.match(/\x1b\[<(\d+);(\d+);(\d+)([Mm])/);
  if (!match) return null;
  return {
    button: parseInt(match[1]!, 10),
    col: parseInt(match[2]!, 10),
    row: parseInt(match[3]!, 10),
    pressed: match[4] === 'M',
  };
}

// Key name detection from raw input
export function keyName(data: Buffer): string {
  const str = data.toString();
  if (str === '\x1b') return 'escape';
  if (str === '\r' || str === '\n') return 'return';
  if (str === '\t') return 'tab';
  if (str === '\x7f') return 'backspace';
  if (str === ' ') return 'space';

  // F-keys
  if (str === '\x1bOP') return 'f1';
  if (str === '\x1bOQ') return 'f2';
  if (str === '\x1bOR') return 'f3';
  if (str === '\x1bOS') return 'f4';
  if (str === '\x1b[15~') return 'f5';
  if (str === '\x1b[17~') return 'f6';
  if (str === '\x1b[18~') return 'f7';
  if (str === '\x1b[19~') return 'f8';
  if (str === '\x1b[24;2~') return 'f13';
  if (str === '\x1b[1;2P') return 'f13';
  if (str.includes('57376')) return 'f13'; // kitty protocol (F13)

  // Arrow keys
  if (str === '\x1b[A') return 'up';
  if (str === '\x1b[B') return 'down';
  if (str === '\x1b[C') return 'right';
  if (str === '\x1b[D') return 'left';

  // Ctrl combinations
  if (data.length === 1 && data[0]! < 27) {
    return 'ctrl+' + String.fromCharCode(data[0]! + 96);
  }

  return str;
}

// Draw a box with border and solid background
export function drawBox(
  row: number,
  col: number,
  width: number,
  height: number,
  title: string,
  lines: string[],
  focused = false,
): string {
  const bg = colors.overlayBg;
  const borderColor = focused ? colors.accentFg + bg : colors.overlayBorder + bg;
  const titleColor = colors.overlayFg + bg + style.bold;
  let out = '';

  // Top border
  const titleStr = title ? ` ${titleColor}${title}${style.reset}${borderColor} ` : '';
  const titleVisLen = title ? title.length + 2 : 0;
  const topFill = width - 2 - titleVisLen;
  out += cursor.to(row, col) + borderColor + '\u250c' + '\u2500' + titleStr;
  out += '\u2500'.repeat(Math.max(0, topFill - 1)) + '\u2510' + style.reset;

  // Content lines
  for (let i = 0; i < height - 2; i++) {
    const line = lines[i] || '';
    const padding = width - 2 - visibleLength(line);
    out += cursor.to(row + 1 + i, col);
    out += borderColor + '\u2502' + style.reset + bg;
    out += line + ' '.repeat(Math.max(0, padding));
    out += style.reset + borderColor + '\u2502' + style.reset;
  }

  // Bottom border
  out += cursor.to(row + height - 1, col);
  out += borderColor + '\u2514' + '\u2500'.repeat(width - 2) + '\u2518' + style.reset;

  return out;
}
