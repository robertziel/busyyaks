import { afterEach, describe, expect, it, vi } from "vitest";
import { markOf, placeMark, spark } from "../lib/sparkline";
import { attachMark } from "./GraphTile";

// Fakes for the two elements and ResizeObserver (vitest runs in node: no DOM).
class FakeObserver {
  static last: FakeObserver;
  observed: unknown[] = [];
  disconnected = false;
  constructor(public cb: () => void) {
    FakeObserver.last = this;
  }
  observe(t: unknown) {
    this.observed.push(t);
  }
  disconnect() {
    this.disconnected = true;
  }
}

const box = (w: number, h: number) => ({ clientWidth: w, clientHeight: h }) as unknown as HTMLElement;
const label = () => {
  const classes = new Set<string>();
  const el = {
    offsetWidth: 40,
    offsetHeight: 11,
    style: {} as Record<string, string>,
    classList: { toggle: (c: string, on: boolean) => (on ? classes.add(c) : classes.delete(c)) },
  };
  return { el: el as unknown as HTMLElement, style: el.style, placed: () => classes.has("placed") };
};

afterEach(() => vi.unstubAllGlobals());

describe("attachMark (the Graph's layout effect)", () => {
  it("places the label at once, again on every resize, and stops observing on cleanup", () => {
    vi.stubGlobal("ResizeObserver", FakeObserver);
    const s = spark([0, 0, 0, 0, 10]);
    const m = markOf(s)!;
    const g = box(200, 44);
    const l = label();
    const stop = attachMark(g, l.el, s.ys, m.level);
    const spot = placeMark(s.ys, m.level, 200, 44, 40, 11)!;
    expect(l.placed()).toBe(true);
    expect(l.style).toEqual({ top: `${spot.top.toFixed(1)}px`, left: "0", right: "auto" });
    expect(FakeObserver.last.observed).toEqual([g]);

    (g as unknown as { clientHeight: number }).clientHeight = 8; // shrunk: no clear spot any more
    FakeObserver.last.cb();
    expect(l.placed()).toBe(false);

    stop();
    expect(FakeObserver.last.disconnected).toBe(true);
  });

  it("the effect's ys key round-trips exactly, gaps included", () => {
    const s = spark([3, null, 7.25, undefined, 1 / 3, 0]);
    expect(JSON.parse(JSON.stringify(s.ys))).toEqual(s.ys);
    expect(s.ys).toContain(null);
  });
});
