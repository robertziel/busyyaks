// the sessions section's lanes — which lane a session lands in, the short names, the Working chip's words,
// the Quiet fold, the chip's selection (keyboard focus / a touch tap → the strip; a click / Enter → the terminal) and
// the arrow keys between chips.
import { describe, expect, it } from "vitest";
import type { AgentSession, TmuxSession } from "../types";
import type { RegisteredSession } from "../vendor/agents_kanban";
import {
  buildLanes,
  CHIP_START,
  chipCard,
  chipReducer,
  elapsedText,
  inTerminal,
  laneOf,
  liveIssue,
  behindKey,
  catchUpAsks,
  catchUpTracker,
  menuPosition,
  triggerHidden,
  needOf,
  nextChip,
  phaseParts,
  phaseWord,
  QUIET_LIMIT,
  quietShown,
  quietWord,
  refocusAfterTerminal,
  regText,
  shortNames,
  type ChipState,
} from "./sessionLanes";

const tmux = (name: string, created = 1): TmuxSession => ({
  name,
  created,
  attached: false,
  terminal_url: `https://t/${name}`,
  claude_url: null,
  ssh_attach: `ssh h -t tmux attach -t ${name}`,
});
const agent = (name: string, state: AgentSession["state"], o: Partial<AgentSession> = {}): AgentSession =>
  ({
    key: `default/${name}`,
    name,
    socket: "default",
    state,
    state_by: null,
    unread: false,
    phase: null,
    live: { tool: null, elapsed_s: null, tokens: null, card: null },
    cards: [],
    asks: [],
    reviews: [],
    dialogs: [],
    waiting_for: [],
    agent: null,
    agent_type: null,
    ...o,
  }) as AgentSession;
const card = (id: number, o = {}) => ({
  id,
  slug: "p",
  title: `card ${id}`,
  column_label: "In progress",
  column_type: "working",
  gate_hold: null,
  blocked_external: null,
  approved_carried_on: false,
  path: `/projects/p?tab=board&card=${id}`,
  ...o,
});

describe("lanes", () => {
  it("blocked and review need you; working works; finished / idle / unknown / no live state are quiet", () => {
    expect(laneOf(agent("a", "blocked"))).toBe("you");
    expect(laneOf(agent("a", "review"))).toBe("you");
    expect(laneOf(agent("a", "working"))).toBe("working");
    for (const s of ["finished", "idle", "unknown"] as const) expect(laneOf(agent("a", s))).toBe("quiet");
    expect(laneOf(null)).toBe("quiet");
  });

  it("buildLanes: each tmux session in one lane, worst first then newest, its registration attached", () => {
    const sessions = ["p_w1", "p_w2", "p_w3", "p_w4", "p_lead"].map((n, i) => tmux(n, i));
    const agents = [
      agent("p_w1", "working"),
      agent("p_w2", "review"),
      agent("p_w3", "blocked"),
      agent("p_lead", "finished"),
      agent("elsewhere", "working"), // another project's session: not a tmux session here
    ];
    const reg = ["p_w1", "p_w2", "p_w3", "p_w4", "p_lead"].map(
      (n) => ({ session: n, type: n === "p_lead" ? "lead" : "worker", launcher: "fullclaude" }) as RegisteredSession,
    );
    const l = buildLanes(sessions, agents, reg);
    expect(l.you.map((x) => x.tmux.name)).toEqual(["p_w3", "p_w2"]);
    expect(l.working.map((x) => x.tmux.name)).toEqual(["p_w1"]);
    expect(l.quiet.map((x) => [x.tmux.name, x.agent?.state ?? null])).toEqual([
      ["p_lead", "finished"],
      ["p_w4", null], // no live state: quiet, never guessed
    ]);
    expect(regText(l.quiet[0]!.reg)).toBe(" · lead · fullclaude");
    expect(regText(l.quiet[1]!.reg)).toBe(" · worker · fullclaude");
    expect(l.quiet[0]!.short).toBe("lead");
  });

  // not read: the list stands as the server sent it (only the sessions the launcher proves it started)
  it("an unread registry calls no session 'not registered': each says why it is unknown", () => {
    const l = buildLanes([tmux("p_a", 2), tmux("p_b", 1)], [], { unknown: "launcher down: ECONNREFUSED" });
    expect(l.quiet.map((x) => regText(x.reg))).toEqual([
      " · registration unknown: launcher down: ECONNREFUSED",
      " · registration unknown: launcher down: ECONNREFUSED",
    ]);
  });

  it("shortNames drops the shared prefix at a _ boundary, never to nothing, never with one session", () => {
    expect([...shortNames(["acme_app_worker", "acme_app_worker_6", "acme_app_teamlead"]).values()]).toEqual([
      "worker",
      "worker_6",
      "teamlead",
    ]);
    expect([...shortNames(["group_repo"]).values()]).toEqual(["group_repo"]);
    expect([...shortNames(["group_repo", "group_repo_1"]).values()]).toEqual(["repo", "repo_1"]);
    expect([...shortNames(["a", "b"]).values()]).toEqual(["a", "b"]);
  });
});

describe("the Working chip", () => {
  it("phase word: the screen's phase, a tool with its name, nothing on screen = working", () => {
    expect(phaseWord(agent("a", "working", { phase: "thinking" }))).toBe("thinking");
    expect(
      phaseWord(
        agent("a", "working", {
          phase: "tool",
          live: { tool: "busyyaks · kanban_comment", elapsed_s: 1, tokens: null, card: 7 },
        }),
      ),
    ).toBe("tool · kanban_comment");
    expect(phaseWord(agent("a", "working", { phase: "tool" }))).toBe("tool");
    expect(phaseWord(agent("a", "working"))).toBe("working");
  });

  // the word is never cut; only the tool's name is a suffix the chip may shorten
  it("phaseParts: the phase word whole + the tool's name apart", () => {
    const tool = agent("a", "working", {
      phase: "tool",
      live: { tool: "busyyaks · kanban_comment", elapsed_s: 1, tokens: null, card: null },
    });
    expect(phaseParts(tool)).toEqual({ word: "tool", tool: "kanban_comment" });
    expect(phaseParts(agent("a", "working", { phase: "tool" }))).toEqual({ word: "tool", tool: null });
    expect(phaseParts(agent("a", "working", { phase: "thinking" }))).toEqual({ word: "thinking", tool: null });
    expect(phaseParts(agent("a", "working"))).toEqual({ word: "working", tool: null });
  });

  it("elapsed as the status line writes it; unknown stays unknown", () => {
    expect([elapsedText(48), elapsedText(252), elapsedText(3780), elapsedText(null)]).toEqual([
      "48s",
      "4m 12s",
      "1h 03m",
      null,
    ]);
  });

  it("its card: only the one a kanban tool acts on now — an owned card is never shown as the one it is on", () => {
    const a = agent("a", "working", { cards: [card(3), card(4)] });
    expect(chipCard(a)).toBeNull();
    const b = agent("a", "working", {
      cards: [card(3), card(4)],
      live: { tool: "x", elapsed_s: 1, tokens: null, card: 4 },
    });
    expect(chipCard(b)).toEqual({ id: 4, title: "card 4", path: "/projects/p?tab=board&card=4" });
    const c = agent("a", "working", { live: { tool: "x", elapsed_s: 1, tokens: null, card: 99 } });
    expect(chipCard(c)).toEqual({ id: 99, title: null, path: null }); // not its own card: named, not linked to a guess
    expect(chipCard(agent("a", "working"))).toBeNull();
  });
});

describe("Quiet", () => {
  it("its word: waiting for CI / blocked externally from its cards, else its state; no live state said so", () => {
    expect(quietWord(agent("a", "idle", { cards: [card(1, { gate_hold: "CI pending" })] }))).toEqual({
      word: "waiting for CI",
      tone: "ci",
    });
    expect(quietWord(agent("a", "idle", { cards: [card(1, { blocked_external: "x" })] })).word).toBe(
      "blocked externally",
    );
    expect(quietWord(agent("a", "finished")).word).toBe("finished");
    expect(quietWord(null)).toEqual({ word: "no live state", tone: "unknown" });
  });

  it(`folds past ${QUIET_LIMIT} behind a count; expanded shows all; the selected one never folds away`, () => {
    const q = buildLanes(
      Array.from({ length: 9 }, (_, i) => tmux(`p_${i}`, 100 - i)),
      [],
      Array.from({ length: 9 }, (_, i) => ({ session: `p_${i}`, type: "worker", launcher: "c" }) as RegisteredSession),
    ).quiet;
    expect(quietShown(q, false, null)).toMatchObject({ hidden: 3 });
    expect(quietShown(q, false, null).shown).toHaveLength(QUIET_LIMIT);
    expect(quietShown(q, true, null)).toMatchObject({ hidden: 0 });
    const sel = quietShown(q, false, "p_8");
    expect([sel.shown.at(-1)!.tmux.name, sel.hidden]).toEqual(["p_8", 2]);
    expect(quietShown(q.slice(0, QUIET_LIMIT), false, null).hidden).toBe(0);
  });
});

describe("Needs you", () => {
  it("the dialog first, then the card question, the review, what it waits for", () => {
    const dialog = {
      question: "Proceed?",
      command: "rm x",
      options: [],
      escape: true,
      free_text: false,
      hash: "h",
      answerable: true,
    };
    const ask = { id: 5, slug: "p", title: "t", question: "A or B?", options: ["A", "B"], path: "/x" };
    const rev = { id: 6, slug: "p", title: "ship", pr_url: null, path: "/y" };
    expect(needOf(agent("a", "blocked", { dialogs: [dialog], asks: [ask] })).kind).toBe("dialog");
    expect(needOf(agent("a", "blocked", { asks: [ask], reviews: [rev] }))).toMatchObject({
      kind: "question",
      question: "A or B?",
    });
    expect(needOf(agent("a", "review", { reviews: [rev] })).kind).toBe("review");
    expect(needOf(agent("a", "blocked", { waiting_for: ["approval"] }))).toEqual({ kind: "waiting", text: "approval" });
  });
});

describe("the chip's selection", () => {
  const run = (...evs: Parameters<typeof chipReducer>[1][]): ChipState => evs.reduce(chipReducer, CHIP_START);

  it("a mouse click and Enter open the terminal; a touch tap only shows the strip", () => {
    // a mouse click opens the terminal and moves no strip in (the lanes below never jump)
    expect(run({ type: "activate", name: "a", pointer: "mouse" })).toEqual({ selected: null, by: null, open: "a" });
    expect(run({ type: "activate", name: "a", pointer: "key" })).toMatchObject({ selected: "a", open: "a" });
    const tap = run({ type: "activate", name: "a", pointer: "touch" });
    expect(tap).toMatchObject({ selected: "a", by: "tap", open: null });
    expect(chipReducer(tap, { type: "openTerminal", name: "a" }).open).toBe("a"); // the strip's Open terminal
    expect(run({ type: "openTerminal", name: "a" }, { type: "closeTerminal" }).open).toBeNull();
  });

  // nothing a mouse pointer passes over changes the layout — only focus (keyboard) and a tap select
  it("only keyboard focus and a touch tap select; a selection stays until another one or a dismiss", () => {
    expect(run({ type: "focus", name: "a" })).toMatchObject({ selected: "a", by: "focus" });
    expect(run({ type: "focus", name: "a" }, { type: "focus", name: "b" }).selected).toBe("b");
    expect(run({ type: "focus", name: "a" }, { type: "activate", name: "b", pointer: "mouse" }).selected).toBe("a");
    expect(run({ type: "focus", name: "a" }, { type: "dismiss" }).selected).toBeNull();
  });

  it("arrow keys walk the chips in lane order; Home / End jump; other keys are not navigation", () => {
    const names = ["you1", "w1", "w2", "q1"];
    expect(nextChip(names, "w1", "ArrowRight")).toBe("w2");
    expect(nextChip(names, "w1", "ArrowDown")).toBe("w2");
    expect(nextChip(names, "w1", "ArrowLeft")).toBe("you1");
    expect(nextChip(names, "you1", "ArrowUp")).toBe("you1");
    expect(nextChip(names, "q1", "ArrowRight")).toBe("q1");
    expect([nextChip(names, "w2", "Home"), nextChip(names, "you1", "End")]).toEqual(["you1", "q1"]);
    expect(nextChip(names, "w1", "Enter")).toBeNull();
    expect(nextChip(names, "gone", "ArrowRight")).toBeNull();
  });
});

describe("liveIssue", () => {
  const data = (o: Record<string, unknown> = {}) =>
    ({ stale: false, age_s: 2, collector_error: null, groups: [], ...o }) as unknown as Parameters<typeof liveIssue>[0];
  it("a fresh read: nothing to say; loading: nothing; no answer + an error: no live state", () => {
    expect(liveIssue(data(), null)).toBeNull();
    expect(liveIssue(undefined, null)).toBeNull();
    expect(liveIssue(undefined, "503 launcher down")).toEqual({
      kind: "none",
      text: "live state unknown: 503 launcher down",
    });
  });
  it("a failed refresh, a stale snapshot, a collector error: the last snapshot, with every reason", () => {
    expect(liveIssue(data(), "502 bad gateway")).toEqual({
      kind: "old",
      text: "showing the last snapshot: refresh failed: 502 bad gateway",
    });
    expect(liveIssue(data({ stale: true, age_s: 41.6, collector_error: "herdr down" }), null)).toEqual({
      kind: "old",
      text: "showing the last snapshot: collector snapshot 42s old · collector: herdr down",
    });
  });
});

describe("liveIssue: the session list (card 614)", () => {
  const data = (o: Record<string, unknown> = {}) =>
    ({ stale: false, age_s: 2, collector_error: null, groups: [], ...o }) as unknown as Parameters<typeof liveIssue>[0];
  it("its failed refresh: the lanes are its last read, said first", () => {
    expect(liveIssue(data(), null, "503 down")).toEqual({
      kind: "old",
      text: "showing the last snapshot: session list refresh failed: 503 down",
    });
    expect(liveIssue(data({ stale: true, age_s: 40 }), "502", "503 down")?.text).toBe(
      "showing the last snapshot: session list refresh failed: 503 down · refresh failed: 502 · collector snapshot 40s old",
    );
    expect(liveIssue(data(), null, null)).toBeNull();
    // the Agents read failed with no answer: both failures said
    expect(liveIssue(undefined, "502", "503 down")).toEqual({
      kind: "none",
      text: "live state unknown: 502 · session list refresh failed: 503 down",
    });
    // the Agents read not answered yet: the list's failure is still said
    expect(liveIssue(undefined, null, "503 down")).toEqual({
      kind: "old",
      text: "showing the last snapshot: session list refresh failed: 503 down",
    });
  });
});

// card 614: the session list and the Agents read are polled apart; one naming what the other lacks asks it again
describe("behindKey + catchUpAsks", () => {
  it("names one read lists that the other does not, sorted, deduplicated, order-free", () => {
    expect(behindKey(["b", "a", "c"], ["c"])).toBe("a\nb");
    expect(behindKey(["a", "b"], ["b", "a"])).toBe("");
    expect(behindKey(["x", "x"], [])).toBe("x");
    expect(behindKey(["b", "a"], [])).toBe(behindKey(["a", "b"], []));
  });
  it("a session the lead spawned: the Agents read lists it first → the session list is asked once", () => {
    const tmux = ["p_teamlead"];
    const k0 = behindKey(["p_teamlead", "other_lead"], tmux); // another project's session: a standing difference
    expect(catchUpAsks(null, k0)).toBe(false); // first render: both reads fresh
    const k1 = behindKey(["p_teamlead", "other_lead", "p_worker_9"], tmux);
    expect(catchUpAsks(k0, k1)).toBe(true); // the new worker → ask
    expect(catchUpAsks(k1, k1)).toBe(false); // re-render, no new read: never a loop
    const k2 = behindKey(["p_teamlead", "other_lead", "p_worker_9"], [...tmux, "p_worker_9"]);
    expect(catchUpAsks(k1, k2)).toBe(false); // the list caught up: back to the standing difference, nothing asked
    // two sessions at once, one read behind by one of them: the newer name asks again
    expect(catchUpAsks("a", "a\nb")).toBe(true);
    expect(catchUpAsks("a\nb", "b")).toBe(false);
  });
  it("a session that ended: the list drops it while the Agents read still has it, then both agree", () => {
    const k0 = behindKey(["a", "b"], ["b", "a"]);
    expect(k0).toBe("");
    const k1 = behindKey(["a", "b"], ["a"]); // the list dropped b first
    expect(catchUpAsks(k0, k1)).toBe(true);
    expect(catchUpAsks(k1, behindKey(["a"], ["a"]))).toBe(false); // agreed: nothing more
  });
});

describe("catchUpTracker: the page's catch-up, render by render (card 614)", () => {
  it("asks once per new difference; a re-render with the same key, the first key or no Agents read asks nothing", () => {
    const step = catchUpTracker();
    expect(step(null)).toBe(false); // the Agents read has not answered: nothing recorded
    expect(step("")).toBe(false); // first key: both reads fresh, only recorded
    expect(step("")).toBe(false); // a re-render (or a new ask function) with the same key
    expect(step("p_worker_9")).toBe(true); // the lead spawned a worker the session list has not seen: ask once
    expect(step("p_worker_9")).toBe(false); // the next renders until the list answers: no second ask
    expect(step(null)).toBe(false); // the Agents read lost (null) keeps the record
    expect(step("p_worker_9")).toBe(false);
    expect(step("p_worker_9\np_worker_10")).toBe(true); // another new name while still behind: ask again
    expect(step("")).toBe(false); // caught up
    expect(step("p_worker_10")).toBe(true); // a name differs again after agreeing: asked
  });
  it("each tracker is its own: two catch-ups on one page never share a record", () => {
    const a = catchUpTracker();
    const b = catchUpTracker();
    expect(a("x")).toBe(false);
    expect(b("y")).toBe(false);
    expect(a("x\ny")).toBe(true);
    expect(b("y")).toBe(false);
  });
});

describe("buildLanes follows the session list (card 614)", () => {
  const tmux = (name: string, created: number) => ({ name, created }) as unknown as TmuxSession;
  const ag = (name: string, state: string) => ({ name, state }) as unknown as AgentSession;
  const regs = (...names: string[]) =>
    names.map((session) => ({ session, type: "worker", launcher: "fullclaude" }) as RegisteredSession);
  it("a session added between two reads gets a chip; one removed leaves every lane", () => {
    const before = buildLanes([tmux("p_lead", 1)], [ag("p_lead", "idle")], regs("p_lead"));
    expect(before.quiet.map((l) => l.tmux.name)).toEqual(["p_lead"]);
    const added = buildLanes(
      [tmux("p_lead", 1), tmux("p_worker", 2)],
      [ag("p_lead", "idle"), ag("p_worker", "working")],
      regs("p_lead", "p_worker"),
    );
    expect(added.working.map((l) => l.tmux.name)).toEqual(["p_worker"]);
    const gone = buildLanes(
      [tmux("p_lead", 1)],
      [ag("p_lead", "idle"), ag("p_worker", "working")],
      regs("p_lead", "p_worker"),
    );
    expect([...gone.you, ...gone.working, ...gone.quiet].map((l) => l.tmux.name)).toEqual(["p_lead"]);
  });
  it("listed before the Agents read has it: Quiet with no live state, never a guessed one", () => {
    const l = buildLanes([tmux("p_new", 3)], [], regs("p_new"));
    expect(l.quiet.map((x) => [x.tmux.name, x.agent])).toEqual([["p_new", null]]);
  });
});

// the ⋯ menu is a fixed portal; where it goes
describe("menuPosition", () => {
  const view = { width: 1440, height: 900 };
  const pop = { width: 240, height: 230 };
  const trig = (top: number, right = 700) => ({ top, bottom: top + 22, left: right - 24, right });
  it("under its trigger, right edges aligned, when there is room below", () => {
    expect(menuPosition(trig(300), pop, view)).toEqual({ top: 326, left: 460, up: false });
  });
  it("up when the window has no room below and more above", () => {
    expect(menuPosition(trig(800), pop, view)).toEqual({ top: 566, left: 460, up: true });
  });
  it("never past the window's edges", () => {
    expect(menuPosition(trig(300, 100), pop, view).left).toBe(8); // a trigger near the left edge
    expect(menuPosition(trig(300, 1440), pop, view).left).toBe(1192); // the right edge: 1440 - 8 - 240
    const tiny = { width: 390, height: 300 };
    const p = menuPosition(trig(120, 380), pop, tiny); // no room either way: kept inside
    expect(p.top).toBeGreaterThanOrEqual(8);
    expect(p.top + pop.height).toBeLessThanOrEqual(300 - 8 + 0.5);
  });
});

// a session that ends while its terminal is open never steals focus from where the operator is typing
describe("focus after a terminal unmounts with its session", () => {
  const body = { tag: "body" } as unknown as Element;
  const input = { tag: "input" } as unknown as Element;
  it("moves to the lanes only when focus was in that terminal and is now lost", () => {
    expect(refocusAfterTerminal(true, body, body)).toBe(true);
    expect(refocusAfterTerminal(true, null, body)).toBe(true);
  });
  it("leaves it alone when the operator is elsewhere (typing in a field, or focus never was in the terminal)", () => {
    expect(refocusAfterTerminal(true, input, body)).toBe(false);
    expect(refocusAfterTerminal(false, body, body)).toBe(false);
    expect(refocusAfterTerminal(false, input, body)).toBe(false);
  });
  it("inTerminal: an element inside .lt, nothing else", () => {
    const el = (inside: boolean) =>
      ({ closest: (s: string) => (s === ".lt" && inside ? {} : null) }) as unknown as Element;
    expect([inTerminal(el(true)), inTerminal(el(false)), inTerminal(null), inTerminal({} as EventTarget)]).toEqual([
      true,
      false,
      false,
      false,
    ]);
  });
});

// a menu whose trigger scrolls out of sight closes (it followed its trigger over the header)
describe("triggerHidden", () => {
  it("under the sticky header or past the window's bottom = hidden; any part visible = not", () => {
    expect(triggerHidden({ top: 20, bottom: 42 }, 56, 900)).toBe(true); // wholly under a 56 px header
    expect(triggerHidden({ top: 40, bottom: 62 }, 56, 900)).toBe(false); // its bottom edge still shows
    expect(triggerHidden({ top: 900, bottom: 922 }, 56, 900)).toBe(true);
    expect(triggerHidden({ top: 300, bottom: 322 }, 56, 900)).toBe(false);
  });
});

// A terminal `claude` started by hand in the repo's directory got a chip of its own on the project page: the page
// shows only the sessions busyyaks runs.
describe("the project page shows only sessions busyyaks runs", () => {
  const tmux = (name: string, created: number) => ({ name, created }) as unknown as Parameters<typeof buildLanes>[0][0];
  const ag = (name: string, state: string) =>
    ({ name, state }) as unknown as NonNullable<Parameters<typeof buildLanes>[1]>[0];
  const lead = { session: "acme_app_teamlead", type: "lead", launcher: "fullclaude" } as RegisteredSession;
  const all = (l: ReturnType<typeof buildLanes>) => [...l.you, ...l.working, ...l.quiet].map((x) => x.tmux.name);

  it("a session started from the terminal in the project's directory gets no chip, working or idle", () => {
    const l = buildLanes(
      [tmux("acme_app", 1), tmux("acme_app_fix", 2), tmux("acme_app_teamlead", 3)],
      [ag("acme_app", "working"), ag("acme_app_fix", "idle"), ag("acme_app_teamlead", "idle")],
      [lead],
    );
    expect(all(l)).toEqual(["acme_app_teamlead"]);
  });

  it("with only terminal sessions in the directory the lanes are empty", () => {
    const l = buildLanes([tmux("acme_app", 1)], [ag("acme_app", "working")], []);
    expect(all(l)).toEqual([]);
  });

  it("names are shortened only among busyyaks's own sessions: a terminal session never shows as 'app'", () => {
    const worker = { session: "acme_app_worker_2", type: "worker", launcher: "fullclaude" } as RegisteredSession;
    const l = buildLanes(
      [tmux("acme_app", 1), tmux("acme_app_teamlead", 2), tmux("acme_app_worker_2", 3)],
      [],
      [lead, worker],
    );
    expect(l.quiet.map((x) => x.short).sort()).toEqual(["teamlead", "worker_2"]);
  });
});
