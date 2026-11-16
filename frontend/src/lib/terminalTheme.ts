// The live terminal's colours (components/LiveTerminal.tsx): the screen (xterm.js theme) and the window around it.
// A fixed constant, not skin tokens: agents colour their output for a dark screen, so the terminal is the same dark
// window on every skin — like a terminal app on a light desktop. Every colour of the terminal is here, once;
// styles/terminal.css reads the window's as --lt-* (set on the terminal's root), never a literal of its own.
import type { ITheme } from "@xterm/xterm";

const BG = "#14161b";
const FG = "#d6d9e0";
const AMBER = "#f2c14e"; // in control
const BLUE = "#6aa5f7";

export const TERMINAL_THEME = {
  background: BG,
  foreground: FG,
  cursor: "#ff9a52",
  cursorAccent: BG,
  selectionBackground: "#6aa5f759",
  selectionInactiveBackground: "#6aa5f733",
  scrollbarSliderBackground: "#d6d9e033",
  scrollbarSliderHoverBackground: "#d6d9e059",
  scrollbarSliderActiveBackground: "#d6d9e080",
  black: "#3b414c",
  red: "#f2616b",
  green: "#6cc97a",
  yellow: "#e5c06a",
  blue: BLUE,
  magenta: "#c58af9",
  cyan: "#56c8d8",
  white: "#c9cdd6",
  brightBlack: "#7d8696",
  brightRed: "#ff8590",
  brightGreen: "#8be29a",
  brightYellow: "#f5d98b",
  brightBlue: "#92bfff",
  brightMagenta: "#d9aaff",
  brightCyan: "#84e0ec",
  brightWhite: "#f4f5f8",
} satisfies ITheme;

// the window: title bar, frame, status bar, buttons — CSS custom properties for styles/terminal.css
export const TERMINAL_CHROME = {
  "--lt-bg": BG,
  "--lt-fg": FG,
  "--lt-dim": "#98a0ae",
  "--lt-bar": "#1f232b",
  "--lt-edge": "#363c47",
  "--lt-fill": "#d6d9e01f",
  "--lt-fill-hover": "#d6d9e038",
  "--lt-thumb": "#d6d9e040",
  "--lt-veil": "#14161bd9",
  "--lt-shadow": "#00000066",
  "--lt-focus": BLUE,
  "--lt-ok": TERMINAL_THEME.green,
  "--lt-bad": TERMINAL_THEME.brightRed,
  "--lt-control": AMBER,
  "--lt-control-ink": "#231a02",
  "--lt-control-fill": "#f2c14e24",
  "--lt-control-ring": "#f2c14e40",
  "--lt-light-close": "#ff5f57",
  "--lt-light-full": "#28c840",
  "--lt-light-glyph": "#000000a6",
} as const;

// WCAG relative luminance contrast of two #rrggbb colours (the theme's test; the screen also sets xterm's
// minimumContrastRatio so text an agent paints in a dark colour stays readable)
export function contrast(a: string, b: string): number {
  const lum = (hex: string) => {
    if (!/^#[0-9a-f]{6}$/i.test(hex)) throw new Error(`not a #rrggbb colour: ${hex}`);
    const ch = [1, 3, 5].map((i) => {
      const c = parseInt(hex.slice(i, i + 2), 16) / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    }) as [number, number, number];
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
  };
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

// The font size at which a cols × rows pane fits the room (CSS px), in half-pixel steps within [min, max]; the pane
// is never resized, so one that does not fit at `min` stays at `min` and scrolls. cell = one cell's size per 1px of
// font size, measured from the drawn terminal. height = null: only the width limits it.
export function fitFontSize(o: {
  cols: number;
  rows: number;
  cell: { w: number; h: number };
  width: number;
  height: number | null;
  min: number;
  max: number;
}): number {
  const byWidth = o.width / (o.cols * o.cell.w);
  const byHeight = o.height === null ? byWidth : o.height / (o.rows * o.cell.h);
  const size = Math.floor(Math.min(byWidth, byHeight) * 2) / 2;
  return Math.min(o.max, Math.max(o.min, size));
}
