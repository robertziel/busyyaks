import { describe, expect, it } from "vitest";
import type { AgentGroup, AgentSession } from "../types";
import {
  cardFlags,
  engineNorm,
  engineTag,
  fullLines,
  paneTitle,
  rowLines,
  rowTitle,
  stateTag,
  subagentFigure,
  why,
} from "./agentRow";

const s = (extra: Partial<AgentSession> = {}) =>
  ({
    name: "proj_teamlead",
    state: "idle",
    state_by: null,
    unread: false,
    cards_known: true,
    cards: [],
    cards_finished: 0,
    asks: [],
    reviews: [],
    dialogs: [],
    waiting_for: [],
    subagents: 0,
    engines: ["Claude"],
    title: null,
    cwd: null,
    phase: null,
    ...extra,
  }) as AgentSession;
type Flags = { gate_hold?: string; blocked_external?: string };
const card = (id: number, column_label: string, flags: Flags = {}) => ({
  id,
  slug: "p",
  title: "t",
  column_label,
  column_type: null,
  gate_hold: flags.gate_hold ?? null,
  blocked_external: flags.blocked_external ?? null,
  path: "/",
});
const ask = { id: 11, slug: "p", title: "Compact rows", question: "A, B or C?", options: [], path: "/" };
const group = (sessions: AgentSession[]) =>
  ({ label: "p", slug: "p", icon: null, state: "idle", sessions }) as AgentGroup;

describe("engineNorm / engineTag", () => {
  it("the norm is the launcher more than half of the sessions run; only another one is tagged", () => {
    const vllm = s({ engines: ["Claude (vLLM)"] });
    const norm = engineNorm([group([s(), s()]), group([vllm])]);
    expect(norm).toBe("Claude");
    expect(engineTag(s(), norm)).toBeNull();
    expect(engineTag(vllm, norm)).toBe("Claude (vLLM)");
  });
  it("no majority (a tie, three launchers, no session) = no norm: every row names its own", () => {
    const hermes = s({ engines: ["Hermes"] });
    expect(engineNorm([group([s(), hermes])])).toBeNull();
    expect(engineNorm([group([s(), hermes, s({ engines: ["Codex"] })])])).toBeNull();
    expect(engineNorm([])).toBeNull();
    expect(engineTag(s(), null)).toBe("Claude");
    expect(engineTag(hermes, null)).toBe("Hermes");
  });
  it("a session with two engines is its own label", () => {
    const both = s({ engines: ["Claude", "Hermes"] });
    expect(engineTag(both, "Claude")).toBe("Claude·Hermes");
  });
});

describe("stateTag", () => {
  it("one short word per state; idle has none", () => {
    expect(stateTag(s({ state: "blocked" }))).toEqual({ word: "needs input", tone: "blocked" });
    expect(stateTag(s({ state: "review" }))).toEqual({ word: "PR review", tone: "review" });
    expect(stateTag(s({ state: "finished" }))).toEqual({ word: "finished", tone: "finished" });
    expect(stateTag(s({ state: "unknown" }))).toEqual({ word: "unknown", tone: "unknown" });
    expect(stateTag(s({ state: "idle" }))).toBeNull();
  });
  it("a working session's word is its live phase; no evidence on screen = working", () => {
    expect(stateTag(s({ state: "working", phase: "thinking" }))?.word).toBe("thinking");
    expect(stateTag(s({ state: "working", phase: "tool" }))?.word).toBe("tool");
    expect(stateTag(s({ state: "working" }))).toEqual({ word: "working", tone: "working" });
  });
});

describe("rowLines", () => {
  it("a row that waits for you: what it waits for, its other cards on a third line", () => {
    const blocked = s({ state: "blocked", asks: [ask], cards: [card(11, "In progress"), card(12, "QA")] });
    expect(rowLines(blocked)).toEqual({ detail: "card #11: A, B or C?", waits: true, more: "#12 QA" });
    expect(why(blocked)).toBe("card #11: A, B or C?");
  });
  it("its only card is the one it waits on: no third line", () => {
    expect(rowLines(s({ state: "blocked", asks: [ask], cards: [card(11, "In progress")] })).more).toBe("");
  });
  it("waiting on a dialog and owning no card: no third line saying no cards; cards unknown is still said", () => {
    const d = {
      question: "Run it?",
      command: null,
      options: [],
      escape: true,
      free_text: false,
      hash: "h",
      answerable: true,
    };
    expect(rowLines(s({ state: "blocked", dialogs: [d] }))).toEqual({ detail: "Run it?", waits: true, more: "" });
    expect(rowLines(s({ state: "blocked", dialogs: [d], cards_known: false })).more).toBe(
      "not registered: cards unknown",
    );
  });
  it("a working row is two lines: its phase word, then its cards", () => {
    const w = s({ state: "working", phase: "tool", cards: [card(13, "In progress")], title: "a pane title" });
    expect(stateTag(w)?.word).toBe("tool");
    expect(rowLines(w)).toEqual({ detail: "#13 In progress", waits: false, more: "" });
  });
  it("owning no card it is named by its pane's title, else its cwd, else no cards", () => {
    expect(rowLines(s({ title: "scratch" })).detail).toBe("scratch");
    expect(rowLines(s({ cwd: "/mnt/projects/busyyaks" })).detail).toBe("projects/busyyaks");
    expect(rowLines(s()).detail).toBe("no cards");
    expect(paneTitle(s())).toBeNull();
  });
  it("cards unknown is always said, never replaced by the title", () => {
    expect(rowLines(s({ cards_known: false, title: "scratch" })).detail).toBe("not registered: cards unknown");
  });
  it("a finished row: how many cards are done", () => {
    expect(rowLines(s({ state: "finished", cards_finished: 3, title: "t" })).detail).toBe("+3 done");
  });
});

describe("cardFlags", () => {
  const ci = card(13, "Human Check", { gate_hold: "pending" });
  const ext = card(15, "QA", { blocked_external: "upstream" });
  it("a card's state is a whole tag, never in the detail the row may cut; the uncut lines keep it", () => {
    const row = s({ state: "working", phase: "thinking", cards: [ci] });
    expect(rowLines(row).detail).toBe("#13 Human Check");
    expect(cardFlags(row)).toEqual([{ word: "CI wait", title: "#13 waiting for CI" }]);
    expect(fullLines(row)).toEqual(["#13 Human Check · waiting for CI"]);
    expect(rowTitle(row).split("\n")).toContain("#13 Human Check · waiting for CI");
  });
  it("each word once, naming every card it is about, in a fixed order", () => {
    const row = s({ cards: [ext, ci, card(14, "Human Check", { gate_hold: "pending" })] });
    expect(cardFlags(row)).toEqual([
      { word: "CI wait", title: "#13, #14 waiting for CI" },
      { word: "ext. wait", title: "#15 blocked externally" },
    ]);
  });
  it("a card already on the why line is not tagged; cards unknown or none: no tags", () => {
    const review = { id: 13, slug: "p", title: "t", pr_url: null, path: "/" };
    expect(cardFlags(s({ state: "review", reviews: [review], cards: [ci] }))).toEqual([]);
    expect(cardFlags(s({ cards_known: false, cards: [ci] }))).toEqual([]);
    expect(cardFlags(s())).toEqual([]);
  });
  it("a waiting row's third line carries the cards without their tails", () => {
    expect(rowLines(s({ state: "blocked", asks: [ask], cards: [ci] })).more).toBe("#13 Human Check");
  });
});

describe("figures and tooltip", () => {
  it("the open row's lines: title and cards, none when the row has neither", () => {
    expect(fullLines(s({ title: "pane", cards_finished: 1 }))).toEqual(["pane", "+1 done"]);
    expect(fullLines(s({ state: "blocked", asks: [ask], cards: [card(11, "In progress")] }))).toEqual([]);
  });
  it("running subagents as a figure; none = no figure", () => {
    expect(subagentFigure(s({ subagents: 3 }))).toEqual({ text: "3 sub", title: "3 subagents running" });
    expect(subagentFigure(s({ subagents: 1 }))?.title).toBe("1 subagent running");
    expect(subagentFigure(s())).toBeNull();
  });
  it("the tooltip carries what the row cuts or leaves out: whole name, state, launcher, title, cards", () => {
    const t = rowTitle(
      s({
        state: "finished",
        unread: true,
        state_by: "cards: 2 in Done",
        subagents: 2,
        title: "pane",
        cards_finished: 2,
      }),
    );
    expect(t.split("\n")).toEqual([
      "proj_teamlead",
      "finished · unread — cards: 2 in Done",
      "Claude",
      "2 subagents running",
      "pane",
      "+2 done",
    ]);
  });
});
