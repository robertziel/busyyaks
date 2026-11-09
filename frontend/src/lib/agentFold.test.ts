import { describe, expect, it } from "vitest";
import type { AgentGroup, AgentSession } from "../types";
import { active, fold } from "./agentFold";

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
});
