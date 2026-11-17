import { afterEach, describe, expect, it, vi } from "vitest";
import type { AgentGroup, AgentSession } from "../types";
import { HIDE_FINISHED_KEY, active, finishedHideable, fold, hideFinishedStored, storeHideFinished } from "./agentFold";

const s = (name: string, state: string, extra: Partial<AgentSession> = {}) =>
  ({ key: `default/${name}`, name, state, subagents: 0, ...extra }) as AgentSession;
const g: AgentGroup = {
  label: "p",
  slug: "p",
  icon: null,
  state: "working",
  sessions: [
    s("work", "working"),
    s("unread", "idle", { unread: true }),
    s("idle1", "idle"),
    s("unk", "unknown"),
    s("lead", "idle", { subagents: 2 }),
  ],
};
const none = new Set<string>();
const visible = (f: ReturnType<typeof fold>) => f.rows.filter((r) => r.visible).map((r) => r.s.name);

describe("agents fold", () => {
  it("active = not idle/unknown, or subagents, or opened", () => {
    expect(g.sessions.map((x) => active(x, none))).toEqual([true, true, false, false, true]);
    expect(active(s("idle1", "idle"), new Set(["default/idle1"]))).toBe(true);
  });
  it("folded: only active rows; the idle count is what unfolding adds", () => {
    const f = fold(g, "all", none, false);
    expect(visible(f)).toEqual(["work", "unread", "lead"]);
    expect([f.shown, f.activeCount, f.idleCount]).toEqual([true, 3, 2]);
  });
  it("unfolded: every row", () => {
    expect(visible(fold(g, "all", none, true))).toEqual(["work", "unread", "idle1", "unk", "lead"]);
  });
  it("an open idle row stays visible while folded", () => {
    expect(visible(fold(g, "all", new Set(["default/unk"]), false))).toEqual(["work", "unread", "unk", "lead"]);
  });
  it("only idle rows: shown with 0 active so the unfold button is reachable", () => {
    const f = fold({ ...g, sessions: [s("a", "idle"), s("b", "unknown")] }, "all", none, false);
    expect([f.shown, f.activeCount, f.idleCount, visible(f).length]).toEqual([true, 0, 2, 0]);
  });
  it("needs you = blocked, review or unread — finished alone is not", () => {
    const h = {
      ...g,
      sessions: [
        s("b", "blocked"),
        s("r", "review"),
        s("u", "idle", { unread: true }),
        s("f", "finished"),
        s("i", "idle"),
      ],
    };
    expect(visible(fold(h, "you", none, true))).toEqual(["b", "r", "u"]);
    expect(active(s("f", "finished"), none)).toBe(true);
  });
  it("filters still apply; a project nothing matches is hidden", () => {
    expect(visible(fold(g, "busy", none, true))).toEqual(["work"]);
    expect(fold({ ...g, sessions: [s("a", "idle")] }, "you", none, true).shown).toBe(false);
    expect(visible(fold(g, "team", none, false))).toEqual(["lead"]);
  });
  it("hide finished: finished rows left out under every filter, counts too; an open one stays", () => {
    const h = {
      ...g,
      sessions: [s("w", "working"), s("f", "finished"), s("fu", "finished", { unread: true }), s("i", "idle")],
    };
    const all = fold(h, "all", none, true, true);
    expect(visible(all)).toEqual(["w", "i"]);
    expect([all.activeCount, all.idleCount]).toEqual([1, 1]);
    expect(visible(fold(h, "you", none, true, true))).toEqual([]);
    expect(fold(h, "you", none, true, true).shown).toBe(false);
    expect(visible(fold(h, "all", new Set(["default/fu"]), true, true))).toEqual(["w", "fu", "i"]);
    expect(visible(fold(h, "all", none, true, false))).toEqual(["w", "f", "fu", "i"]);
  });
  it("a project of only finished sessions is hidden while the toggle is on", () => {
    expect(fold({ ...g, sessions: [s("f", "finished")] }, "all", none, false, true).shown).toBe(false);
  });
});

describe("hide finished: the chip's count", () => {
  it("counts the finished sessions over every project, minus the open ones", () => {
    const a = { ...g, sessions: [s("f1", "finished"), s("f2", "finished", { unread: true }), s("w", "working")] };
    const b = { ...g, slug: "q", sessions: [s("f3", "finished"), s("i", "idle")] };
    expect(finishedHideable([a, b], none)).toBe(3);
    expect(finishedHideable([a, b], new Set(["default/f2"]))).toBe(2);
    expect(finishedHideable([], none)).toBe(0);
  });
});

describe("hide finished: remembered", () => {
  afterEach(() => vi.unstubAllGlobals());
  const memory = () => {
    const m = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (k: string) => m.get(k) ?? null,
      setItem: (k: string, v: string) => void m.set(k, v),
    });
    return m;
  };
  it("off until set; on and off round-trip under its key", () => {
    const m = memory();
    expect(hideFinishedStored()).toBe(false);
    storeHideFinished(true);
    expect([m.get(HIDE_FINISHED_KEY), hideFinishedStored()]).toEqual(["1", true]);
    storeHideFinished(false);
    expect([m.get(HIDE_FINISHED_KEY), hideFinishedStored()]).toEqual(["0", false]);
  });
  it("no storage (private mode): off, and storing never throws", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    });
    expect(hideFinishedStored()).toBe(false);
    expect(() => storeHideFinished(true)).not.toThrow();
  });
});
