import { describe, expect, it } from "vitest";
import { contrast, fitFontSize, TERMINAL_CHROME, TERMINAL_THEME } from "./terminalTheme";

const ANSI = [
  "red",
  "green",
  "yellow",
  "blue",
  "magenta",
  "cyan",
  "white",
  "brightBlack",
  "brightRed",
  "brightGreen",
  "brightYellow",
  "brightBlue",
  "brightMagenta",
  "brightCyan",
  "brightWhite",
] as const;

describe("terminal theme", () => {
  it("contrast is the WCAG ratio", () => {
    expect(contrast("#000000", "#ffffff")).toBeCloseTo(21, 5);
    expect(contrast("#ffffff", "#000000")).toBeCloseTo(21, 5);
    expect(contrast("#777777", "#777777")).toBe(1);
    expect(() => contrast("#fff", "#000000")).toThrow(/not a #rrggbb colour/);
  });

  it("every ANSI text colour reads on the screen (4.5:1); black is the one dark colour", () => {
    for (const name of ANSI) {
      expect(contrast(TERMINAL_THEME[name], TERMINAL_THEME.background), name).toBeGreaterThanOrEqual(4.5);
    }
    expect(contrast(TERMINAL_THEME.foreground, TERMINAL_THEME.background)).toBeGreaterThanOrEqual(7);
    expect(contrast(TERMINAL_THEME.black, TERMINAL_THEME.background)).toBeGreaterThan(1.3);
  });

  it("each bright colour is lighter than its normal one", () => {
    const pairs = [
      ["black", "brightBlack"],
      ["red", "brightRed"],
      ["green", "brightGreen"],
      ["yellow", "brightYellow"],
      ["blue", "brightBlue"],
      ["magenta", "brightMagenta"],
      ["cyan", "brightCyan"],
      ["white", "brightWhite"],
    ] as const;
    for (const [normal, bright] of pairs) {
      expect(contrast(TERMINAL_THEME[bright], "#000000"), bright).toBeGreaterThan(
        contrast(TERMINAL_THEME[normal], "#000000"),
      );
    }
  });

  it("the window's text reads on its bars", () => {
    const c = TERMINAL_CHROME;
    expect(contrast(c["--lt-fg"], c["--lt-bar"])).toBeGreaterThanOrEqual(7);
    expect(contrast(c["--lt-dim"], c["--lt-bar"])).toBeGreaterThanOrEqual(4.5);
    expect(contrast(c["--lt-control"], c["--lt-bar"])).toBeGreaterThanOrEqual(4.5);
    expect(contrast(c["--lt-bad"], c["--lt-bar"])).toBeGreaterThanOrEqual(4.5);
    expect(contrast(c["--lt-control-ink"], c["--lt-control"])).toBeGreaterThanOrEqual(7);
    expect(contrast(c["--lt-edge"], c["--lt-bg"])).toBeGreaterThan(1.3);
  });
});

describe("fitFontSize", () => {
  const cell = { w: 0.6, h: 1.25 };
  const fit = (o: { cols?: number; rows?: number; width: number; height?: number | null }) =>
    fitFontSize({
      cols: o.cols ?? 110,
      rows: o.rows ?? 32,
      cell,
      width: o.width,
      height: o.height ?? null,
      min: 10,
      max: 14,
    });

  it("the largest half-pixel size at which the columns fit", () => {
    expect(fit({ width: 760 })).toBe(11.5); // 760 / 66 = 11.51
    expect(fit({ width: 792 })).toBe(12);
  });
  it("never above max, never below min (a pane too wide scrolls)", () => {
    expect(fit({ width: 4000 })).toBe(14);
    expect(fit({ width: 330 })).toBe(10);
  });
  it("the height limits it too when given", () => {
    expect(fit({ width: 4000, height: 480 })).toBe(12); // 480 / 40
    expect(fit({ width: 760, height: 4000 })).toBe(11.5);
  });
});
