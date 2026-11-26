// The project page's sessions section as three status lanes: Needs you (a dialog on its screen, a
// card question for the operator, a handed-over card to review) · Working · Quiet (finished, idle, unknown). Each tmux
// session busyyaks runs for the project lands in exactly one lane, from the Agents sidebar's own read (/api/agents) — a session that
// read does not list has no live state: Quiet, "no live state", never a guessed one. Pure: the view and its tests use it.
import type { AgentCard, AgentSession, AgentsData, TmuxSession } from "../types";
import type { RegisteredSession } from "../vendor/agents_kanban";

export type Lane = "you" | "working" | "quiet";

export type LaneSession = {
  tmux: TmuxSession;
  short: string; // the name without the prefix every session of the project shares (the full name is in the menu)
  agent: AgentSession | null; // null = /api/agents does not list it, or was not read (liveRead false): no live state
  liveRead: boolean; // the Agents read answered — false: nobody read this session's live state (not "not listed")
  // its open registration (type · launcher); { unknown } = the registry was not read (why). Never "started by hand":
  // buildLanes keeps only the sessions busyyaks runs
  reg: RegisteredSession | RegistryUnknown;
  lane: Lane;
};

export type RegistryUnknown = { unknown: string };

export type Lanes = { you: LaneSession[]; working: LaneSession[]; quiet: LaneSession[] };

// how many Quiet pills show before the rest fold behind "+N quiet"
export const QUIET_LIMIT = 6;

// unread (its turn ended since you last looked) is a flag, not a state: an unread idle / finished session is Quiet, with
// the unread dot on its face — nothing it asks for is waiting on you (its question or dialog would make it blocked)
export function laneOf(a: AgentSession | null): Lane {
  if (!a) return "quiet";
  if (a.state === "blocked" || a.state === "review") return "you";
  if (a.state === "working") return "working";
  return "quiet";
}

// the prefix every name shares, cut at a "_" boundary — only with 2+ sessions, and only when each keeps a name
export function shortNames(names: string[]): Map<string, string> {
  const out = new Map(names.map((n) => [n, n]));
  if (names.length < 2) return out;
  let p = names[0] ?? "";
  for (const n of names) while (!n.startsWith(p)) p = p.slice(0, -1);
  const cut = p.lastIndexOf("_");
  if (cut < 0) return out;
  const prefix = p.slice(0, cut + 1);
  if (names.some((n) => n.length <= prefix.length)) return out;
  names.forEach((n) => out.set(n, n.slice(prefix.length)));
  return out;
}

const RANK: Record<string, number> = { blocked: 0, review: 1, working: 2, finished: 3, idle: 4, unknown: 5 };

// Only the sessions busyyaks runs: a tmux session with an open registration (the operator's Launch, the lead's spawn).
// A session started by hand in the repo's directory (a terminal `claude`) is not busyyaks's: it gets no chip.
// registrations: the launcher's open registrations, or { unknown: why } when they were not read — then the list stands
// as the server sent it (already only the sessions the launcher proves it started), each saying why its registration
// is unknown, never called "not registered" (that would state as fact what nobody read)
export function buildLanes(
  sessions: TmuxSession[],
  agents: AgentSession[] | null, // null = the Agents read has not answered
  registrations: RegisteredSession[] | RegistryUnknown,
): Lanes {
  const live = new Map((agents ?? []).map((a) => [a.name, a]));
  const unknown = Array.isArray(registrations) ? null : registrations;
  const reg = new Map((Array.isArray(registrations) ? registrations : []).map((r) => [r.session, r]));
  const ours = sessions.flatMap((s) => {
    const r = unknown ?? reg.get(s.name);
    return r ? [{ s, r }] : [];
  });
  const short = shortNames(ours.map(({ s }) => s.name));
  const rows = ours.map(({ s, r }): LaneSession => {
    const agent = live.get(s.name) ?? null;
    return {
      tmux: s,
      short: short.get(s.name) ?? s.name,
      agent,
      liveRead: agents !== null,
      reg: r,
      lane: laneOf(agent),
    };
  });
  // worst first inside a lane (blocked before review, finished before idle), then the newest session
  const order = (a: LaneSession, b: LaneSession) =>
    (RANK[a.agent?.state ?? "unknown"] ?? 9) - (RANK[b.agent?.state ?? "unknown"] ?? 9) ||
    b.tmux.created - a.tmux.created;
  const pick = (l: Lane) => rows.filter((r) => r.lane === l).sort(order);
  return { you: pick("you"), working: pick("working"), quiet: pick("quiet") };
}

// the registration when it was read; null when the registry was not read
export function registered(reg: LaneSession["reg"]): RegisteredSession | null {
  return "unknown" in reg ? null : reg;
}

// the detail strip's registration words: " · type · launcher", or why it is unknown
export function regText(reg: LaneSession["reg"]): string {
  if ("unknown" in reg) return ` · registration unknown: ${reg.unknown}`;
  return ` · ${reg.type} · ${reg.launcher}`;
}

// The Working chip's phase word: the screen's phase; a running tool with its name; a turn that ended while its
// background work runs = "waiting" + what ("waiting · 1 monitor"); nothing on screen = "working"
export function phaseWord(a: AgentSession): string {
  const p = phaseParts(a);
  return p.tool ? `${p.word} · ${p.tool}` : p.word;
}

// The phase as the chip draws it: the word (always shown whole: "tool", "thinking", "waiting", "working") and the
// running tool's name / the background work as a suffix the chip may cut (an ellipsis over the whole phase left
// "to…" / "thi…")
export function phaseParts(a: AgentSession): { word: string; tool: string | null } {
  if (a.phase === "tool") return { word: "tool", tool: a.live.tool ? toolName(a.live.tool) : null };
  if (a.phase === "background") return { word: "waiting", tool: a.live.background };
  return { word: a.phase ?? "working", tool: null };
}

// "busyyaks · kanban_comment" → "kanban_comment"; "Bash" stays
export const toolName = (t: string) => t.split(" · ").at(-1) ?? t;

// the turn's elapsed seconds as the status line writes them: 48s · 4m 12s · 1h 03m
export function elapsedText(s: number | null): string | null {
  if (s === null) return null;
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`;
}

// the card a chip names: only the one a kanban tool acts on now (the screen) — none shown = null; a card it merely
// owns is never shown as the card it is on
export function chipCard(a: AgentSession | null): { id: number; title: string | null; path: string | null } | null {
  if (!a || a.live.card === null) return null;
  const own = [...a.cards, ...a.asks, ...a.reviews].find((c) => c.id === a.live.card);
  return { id: a.live.card, title: own?.title ?? null, path: own?.path ?? null };
}

// the card a "waiting for CI" pill names: its card held at a gate for CI — null = none
export function heldCard(a: AgentSession | null): AgentCard | null {
  return a?.cards.find((c) => c.gate_hold) ?? null;
}

// The Quiet pill's word: what its cards wait for (CI, the world), else its state; no live state = said so
export function quietWord(a: AgentSession | null): { word: string; tone: "ci" | "ext" | "done" | "idle" | "unknown" } {
  if (!a) return { word: "no live state", tone: "unknown" };
  if (heldCard(a)) return { word: "waiting for CI", tone: "ci" };
  if (a.cards.some((c) => c.blocked_external)) return { word: "blocked externally", tone: "ext" };
  if (a.state === "finished") return { word: "finished", tone: "done" };
  if (a.state === "idle") return { word: "idle", tone: "idle" };
  return { word: a.state, tone: "unknown" };
}

// Quiet past QUIET_LIMIT: the first ones + how many fold behind "+N quiet"; never folds the selected one away
export function quietShown(
  quiet: LaneSession[],
  expanded: boolean,
  selected: string | null,
): { shown: LaneSession[]; hidden: number } {
  if (expanded || quiet.length <= QUIET_LIMIT) return { shown: quiet, hidden: 0 };
  const shown = quiet.slice(0, QUIET_LIMIT);
  const sel = quiet.find((q) => q.tmux.name === selected);
  if (sel && !shown.includes(sel)) shown.push(sel);
  return { shown, hidden: quiet.length - shown.length };
}

// What the Needs-you card shows: the dialog on its screen (its keys pressed in the session), the card question (its
// choices posted as the operator's answer), the card handed over for review (its PR), or what the collector says it
// waits for — the first one that applies, in that order.
export type Need =
  | { kind: "dialog"; question: string; command: string | null; dialog: NonNullable<AgentSession["dialogs"][number]> }
  | { kind: "question"; question: string; card: AgentSession["asks"][number] }
  | { kind: "review"; card: AgentSession["reviews"][number] }
  | { kind: "waiting"; text: string };

export function needOf(a: AgentSession): Need {
  const d = a.dialogs[0];
  if (d) return { kind: "dialog", question: d.question || "a dialog is on its screen", command: d.command, dialog: d };
  const q = a.asks[0];
  if (q) return { kind: "question", question: q.question || q.title, card: q };
  const r = a.reviews[0];
  if (r) return { kind: "review", card: r };
  return { kind: "waiting", text: a.waiting_for[0] ?? a.state_by ?? "waiting" };
}

export const NEED_WORD: Record<Need["kind"], string> = {
  dialog: "dialog",
  question: "question",
  review: "PR review",
  waiting: "waiting",
};

// ── the chip's interaction: keyboard focus or a touch tap select it (its detail strip), a mouse click or Enter opens its
// terminal. On touch, a tap only selects: the strip's explicit "Open terminal" button opens it. A mouse hover selects
// nothing (a strip that appears under the lane on hover moves every lane below while the pointer travels — a
// pointer aimed at a lower chip landed on another one); the chip's title and its own ⋯ serve the mouse.
export type ChipState = { selected: string | null; by: "focus" | "tap" | null; open: string | null };
export type ChipEvent =
  | { type: "focus"; name: string }
  | { type: "activate"; name: string; pointer: "mouse" | "touch" | "pen" | "key" }
  | { type: "openTerminal"; name: string }
  | { type: "closeTerminal" }
  | { type: "dismiss" };

export const CHIP_START: ChipState = { selected: null, by: null, open: null };

export function chipReducer(s: ChipState, e: ChipEvent): ChipState {
  switch (e.type) {
    case "focus":
      return { ...s, selected: e.name, by: "focus" };
    case "activate":
      if (e.pointer === "touch") return { ...s, selected: e.name, by: "tap" };
      // a mouse click opens the terminal and moves no strip in; Enter on a focused chip keeps its strip
      return e.pointer === "key" ? { ...s, selected: e.name, by: "focus", open: e.name } : { ...s, open: e.name };
    case "openTerminal":
      return { ...s, open: e.name };
    case "closeTerminal":
      return { ...s, open: null };
    case "dismiss":
      return { ...s, selected: null, by: null };
  }
}

// Arrow keys move between the chips (one tab stop per chip's main button stays; the arrows are a shortcut):
// → / ↓ next, ← / ↑ previous, Home / End the ends; null = not a navigation key
export function nextChip(names: string[], current: string, key: string): string | null {
  const i = names.indexOf(current);
  if (i < 0 || names.length === 0) return null;
  if (key === "ArrowRight" || key === "ArrowDown") return names[Math.min(i + 1, names.length - 1)] ?? null;
  if (key === "ArrowLeft" || key === "ArrowUp") return names[Math.max(i - 1, 0)] ?? null;
  if (key === "Home") return names[0] ?? null;
  if (key === "End") return names[names.length - 1] ?? null;
  return null;
}

// Whether the lanes show a live read, and why not (as the Agents sidebar words it): no answer yet with an error = every
// session has no live state; an answer whose refresh failed, a stale collector snapshot or a collector error = the lanes
// show the LAST snapshot — dimmed, no pulse, no answer button (a key pressed on an old screen is a guess)
export type LiveIssue = { kind: "none" | "old"; text: string } | null;

// sessionsError = the project's session list (/api/projects/:slug/sessions) failed its last refresh: the lanes are that
// list's last read — a session started or ended since is missing or still shown (card 614)
export function liveIssue(
  data: AgentsData | undefined,
  error: string | null,
  sessionsError: string | null = null,
): LiveIssue {
  if (!data) {
    if (error) {
      const list = sessionsError ? ` · session list refresh failed: ${sessionsError}` : "";
      return { kind: "none", text: `live state unknown: ${error}${list}` };
    }
    return sessionsError
      ? { kind: "old", text: `showing the last snapshot: session list refresh failed: ${sessionsError}` }
      : null;
  }
  const why = [
    sessionsError ? `session list refresh failed: ${sessionsError}` : null,
    error ? `refresh failed: ${error}` : null,
    data.stale ? `collector snapshot ${Math.round(data.age_s)}s old` : null,
    data.collector_error ? `collector: ${data.collector_error}` : null,
  ].filter((x): x is string => x !== null);
  return why.length ? { kind: "old", text: `showing the last snapshot: ${why.join(" · ")}` } : null;
}

// Where a ⋯ menu (a fixed portal in <body>) goes: under its trigger, right edges aligned; up when the window has no
// room below and more above; never past the window's edges (8 px margin). Rects in viewport px.
export type MenuPos = { top: number; left: number; up: boolean };
type Rect = { top: number; bottom: number; left: number; right: number };

export function menuPosition(
  trigger: Rect,
  pop: { width: number; height: number },
  view: { width: number; height: number },
): MenuPos {
  const m = 8;
  const below = view.height - trigger.bottom;
  const up = below < pop.height + m && trigger.top > below;
  const top = up
    ? Math.max(m, trigger.top - 4 - pop.height)
    : Math.min(trigger.bottom + 4, Math.max(m, view.height - m - pop.height));
  const left = Math.min(Math.max(m, trigger.right - pop.width), Math.max(m, view.width - m - pop.width));
  return { top: Math.round(top), left: Math.round(left), up };
}

// whether a focus target is inside a live terminal (LiveTerminal's root .lt)
export const inTerminal = (t: EventTarget | null): boolean =>
  !!(t && typeof (t as Element).closest === "function" && (t as Element).closest(".lt"));

// A terminal that unmounted with its session: move focus to the lanes only if focus was in that terminal (the last
// focusin was inside it) and is now lost (on <body> or nowhere) — never take it from where someone else put it
export function refocusAfterTerminal(lastInTerminal: boolean, active: Element | null, body: Element | null): boolean {
  return lastInTerminal && (active === null || active === body);
}

// a ⋯ menu's trigger is out of sight: wholly under the sticky header (its bottom edge) or past the window's bottom
export function triggerHidden(
  trigger: { top: number; bottom: number },
  headerBottom: number,
  viewHeight: number,
): boolean {
  return trigger.bottom <= headerBottom || trigger.top >= viewHeight;
}

// The lanes join two reads polled apart: the project's tmux sessions and the Agents read. A name one lists and the other
// does not = that other read is behind (a session just started or ended): it is asked again at once instead of at its
// next tick (card 614). The key changes only when that set changes, so each new difference asks once, never in a loop.
// Names are sorted: the key does not depend on either read's order.
export function behindKey(listed: string[], other: string[]): string {
  const known = new Set(other);
  return [...new Set(listed.filter((n) => !known.has(n)))].sort().join("\n");
}

// Whether a read is asked again: the difference gained a name it did not hold before (a session just started or ended).
// The first key only records (both reads are fresh then); a difference that shrank — the other read caught up — or
// closed ("" = they agree) asks nothing.
export function catchUpAsks(before: string | null, key: string): boolean {
  if (before === null || key === "") return false;
  const had = new Set(before === "" ? [] : before.split("\n"));
  return key.split("\n").some((n) => !had.has(n));
}

// A launcher hiccup: /api/projects/:slug/sessions still answers 200, with launcher_error and NO sessions (it could not
// ask). Shown as is, every live session would leave the lanes until the launcher answers again (card 275). So the list
// the launcher last gave is held — and said (`held` = why, fed to liveIssue as the list's refresh failure: dimmed);
// none held yet (the launcher was down from the first read) → the empty list, the page's "Launcher down" flash says
// why. The next answer with no launcher_error replaces it: a session that ended meanwhile leaves then.
export function heldSessions(
  answer: { sessions: TmuxSession[]; launcher_error: string | null } | undefined,
  lastGood: TmuxSession[] | null,
): { sessions: TmuxSession[]; held: string | null } {
  if (!answer) return { sessions: lastGood ?? [], held: null };
  if (!answer.launcher_error) return { sessions: answer.sessions, held: null };
  return lastGood ? { sessions: lastGood, held: answer.launcher_error } : { sessions: answer.sessions, held: null };
}

// The catch-up of one read, as the page runs it (Sessions' useCatchUp): fed the difference key on every render — null
// while the Agents read has not answered (nothing recorded, nothing asked) — it says whether to ask again now. The first
// key only records; the same key again (a re-render, a new `ask` function) asks nothing; each new name asks once.
export function catchUpTracker(): (key: string | null) => boolean {
  let prev: string | null = null;
  return (key) => {
    if (key === null) return false;
    const before = prev;
    prev = key;
    return catchUpAsks(before, key);
  };
}
