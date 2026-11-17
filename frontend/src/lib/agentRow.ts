// The Agents sidebar's compact row: what each of its lines says. The name owns line 1 (beside it only its age); line 2
// is one short state word + the card tags + the figures (launcher off the norm, running subagents), all drawn whole,
// and one detail that may be cut; a third line exists only for a row that waits for you and owns other cards. The
// launcher is named only where it differs from what most sessions run. Pure: the view and its tests use it.
import type { AgentGroup, AgentSession, AgentState } from "../types";

export const STATE_LABEL: Record<AgentState, string> = {
  blocked: "needs input",
  review: "PR review",
  working: "working",
  finished: "finished",
  idle: "idle",
  unknown: "unknown",
};

type Card = AgentSession["cards"][number];

// what a card's row adds: it waits for CI or for the world — neither for you. `word` = the compact row's tag, drawn
// whole; `text` = the uncut lines' tail
const FLAGS: { on: (c: Card) => boolean; word: string; text: string }[] = [
  { on: (c) => !!c.gate_hold, word: "CI wait", text: "waiting for CI" },
  { on: (c) => !!c.blocked_external, word: "ext. wait", text: "blocked externally" },
];

const tail = (c: Card) =>
  FLAGS.filter((f) => f.on(c))
    .map((f) => ` · ${f.text}`)
    .join("");

// the cards not already on the why line (its questions and reviews)
const otherCards = (s: AgentSession): Card[] => {
  const shown = new Set([...s.asks, ...s.reviews].map((c) => c.id));
  return s.cards.filter((c) => !shown.has(c.id));
};

// The cards it owns that are not done, by their column's label, then how many are — or that it owns none. `tails`
// false = without what each card waits for (the compact row draws that as whole tags: cardFlags)
export function cardLine(s: AgentSession, tails = true): string {
  if (!s.cards_known) return "not registered: cards unknown";
  const parts = otherCards(s).map((c) => `#${c.id} ${c.column_label}${tails ? tail(c) : ""}`);
  if (s.cards_finished > 0) parts.push(`+${s.cards_finished} done`);
  return parts.length ? parts.join(" · ") : s.asks.length + s.reviews.length ? "" : "no cards";
}

// the compact row's card tags, each once, drawn whole at the end of line 2 (the cut detail never hides them):
// `title` = the cards each one is about
export function cardFlags(s: AgentSession): { word: string; title: string }[] {
  if (!s.cards_known) return [];
  const others = otherCards(s);
  return FLAGS.flatMap((f) => {
    const ids = others.filter(f.on).map((c) => `#${c.id}`);
    return ids.length ? [{ word: f.word, title: `${ids.join(", ")} ${f.text}` }] : [];
  });
}

// the one line of a blocked / review session: what it waits for
export function why(s: AgentSession): string {
  const d = s.dialogs[0];
  if (d) return d.question || d.command || "a dialog is on its screen";
  if (s.waiting_for[0]) return s.waiting_for[0];
  const a = s.asks[0];
  if (a) return `card #${a.id}: ${a.question || a.title}`;
  const r = s.reviews[0];
  if (r) return `card #${r.id} in review: ${r.title}`;
  return s.state_by ?? "waiting";
}

// the pane's title, else the last two dirs of its cwd — null when it has neither
export const paneTitle = (s: AgentSession): string | null =>
  s.title ?? (s.cwd ? s.cwd.split("/").slice(-2).join("/") : null);

const label = (s: AgentSession) => s.engines.join("·");

// The launcher most sessions run: the one label MORE than half of them carry — null when none does (then every row
// names its own: with no majority nothing is "the norm")
export function engineNorm(groups: AgentGroup[]): string | null {
  const all = groups.flatMap((g) => g.sessions);
  const count = new Map<string, number>();
  for (const s of all) count.set(label(s), (count.get(label(s)) ?? 0) + 1);
  for (const [l, n] of count) if (n * 2 > all.length) return l;
  return null;
}

// the launcher tag a row shows: only one that is not the norm (the norm is in the tooltip and the open row)
export const engineTag = (s: AgentSession, norm: string | null): string | null => (label(s) === norm ? null : label(s));

export type RowTag = { word: string; tone: AgentState };

// The state as ONE short word, drawn whole: a working session's is its phase (thinking · tool · writing · subagents;
// no evidence on screen = "working"); an idle session has none — its dot says it
export function stateTag(s: AgentSession): RowTag | null {
  if (s.state === "idle") return null;
  if (s.state === "working") return { word: s.phase ?? "working", tone: "working" };
  return { word: STATE_LABEL[s.state], tone: s.state };
}

export type RowLines = {
  detail: string; // line 2, after the state word: cut with an ellipsis when it does not fit
  waits: boolean; // the detail is what it waits for (drawn in the state's colour)
  more: string; // line 3 — "" = no third line
};

// Line 2's detail and the optional line 3 — the cards without their tails (cardFlags draws those whole). A row that
// waits for you: what it waits for, then its other cards below.
// Any other row is two lines: its cards — or, owning none, the pane's title (a session with no
// card is named by what it does); "not registered: cards unknown" is always said
export function rowLines(s: AgentSession): RowLines {
  const cards = cardLine(s, false);
  if (s.state === "blocked" || s.state === "review")
    return { detail: why(s), waits: true, more: cards === "no cards" ? "" : cards };
  const about = cards === "no cards" ? (paneTitle(s) ?? cards) : cards;
  return { detail: about, waits: false, more: "" };
}

// the open row's uncut lines: the pane's title and every card — [] when it has neither
export const fullLines = (s: AgentSession): string[] => [paneTitle(s), cardLine(s)].filter((l): l is string => !!l);

// the figure at the end of line 2: its running subagents — null = none
export const subagentFigure = (s: AgentSession): { text: string; title: string } | null =>
  s.subagents > 0
    ? { text: `${s.subagents} sub`, title: `${s.subagents} ${s.subagents === 1 ? "subagent" : "subagents"} running` }
    : null;

// the row's tooltip: everything the compact row may cut or leave out
export function rowTitle(s: AgentSession): string {
  const state = `${STATE_LABEL[s.state]}${s.unread ? " · unread" : ""}${s.state_by ? ` — ${s.state_by}` : ""}`;
  const cards = cardLine(s);
  return [s.name, state, label(s), subagentFigure(s)?.title, paneTitle(s), cards].filter(Boolean).join("\n");
}
