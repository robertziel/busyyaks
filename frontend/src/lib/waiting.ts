// The "waiting for you" widget's data (GET /api/waiting, the engine's Api#waiting) and the pure bits the view shows.
import type { CarriedOn, LaunchFailure, LeadEnd } from "../vendor/agents_kanban";
import { projectPath } from "./format";

// kind: "ask" = flagged needs_operator (a question, in whatever column) · "review" = in a gate column (work to check, a
// PR to merge) · else the column key. `held` / `external` cards carry kind "held" / "external".
export type WaitingCard = {
  id: number;
  title: string;
  column: string;
  column_label: string;
  kind: string;
  since: string | null;
  needs_operator: boolean;
  blocked: boolean;
  question_first_line: string | null;
  blocked_first_line?: string | null;
  handoff_first_line?: string | null;
  gate_hold?: string | null;
  // the progress watch: why a card in a work column waits for you ("no progress for 90 min (since 14:02)")
  progress_stale?: string | null;
  owner_session: string | null;
  // every card, from the engine: when / who approved it (null = not approved) and — carried on by its agent —
  // where the agent takes it next (final = it merges); an approved card nobody owns waits with carried_on null
  approved: string | null;
  approved_by: string | null;
  carried_on: CarriedOn | null;
};
export type WaitingProject = { slug: string; icon: string | null; count: number; cards: WaitingCard[] };
// projects: the cards waiting for the operator (total = their sum). held: gate cards CI holds (not approvable now);
// external: blocked_external cards (waiting for the world) — neither counts as waiting for you.
// launch_failures: the sessions whose start failed in the last day (a launch or a lead's spawn: claude never came
// up); lead_ends: the boards whose lead ended on its own (gone from the host — never the operator's stop; nothing
// relaunches it: press Launch) — the layout's LaunchFailureAlert opens a modal for the ones this viewer has
// not dismissed
export type Waiting = {
  waiting_columns: string[];
  total: number;
  projects: WaitingProject[];
  held: WaitingProject[];
  external: WaitingProject[];
  // gate cards the operator approved that their agent carries on (Awaiting merge after the final Approve):
  // shown, never counted as waiting for you
  approved: WaitingProject[];
  launch_failures: LaunchFailure[];
  lead_ends: LeadEnd[];
};

export const cardHref = (slug: string, id: number) => `${projectPath(slug)}?tab=board&card=${id}`;

// The widget's segments, by what each asks of the operator, most important first: a question to
// answer · work to review (every other waiting card: ask + review = total) · waiting on CI or the world (held +
// external) · approved, its agent carrying it on — the last two shown, never counted as waiting for you,
// never in the dock badge.
export type Kind = "ask" | "review" | "external" | "approved";
export const KINDS: readonly Kind[] = ["ask", "review", "external", "approved"];
export const KIND_LABEL: Record<Kind, string> = {
  ask: "to answer",
  review: "to review",
  external: "external",
  approved: "approved",
};
export type KindProject = { slug: string; name: string; icon: string | null; count: number };
export type KindRow = { slug: string; name: string; icon: string | null; card: WaitingCard };
export type KindGroup = { kind: Kind; count: number; projects: KindProject[]; rows: KindRow[] };

const shortName = (slug: string) => slug.split("/").pop() || slug;

function group(kind: Kind, sources: WaitingProject[], pick: (c: WaitingCard) => boolean): KindGroup {
  // oldest first (the longest wait on top), an unknown time last, then by card id
  const at = (c: WaitingCard) => (c.since ? Date.parse(c.since) : NaN);
  const rows: KindRow[] = sources
    .flatMap((p) => p.cards.filter(pick).map((card) => ({ slug: p.slug, name: shortName(p.slug), icon: p.icon, card })))
    .sort((a, b) => {
      const x = at(a.card);
      const y = at(b.card);
      if (Number.isNaN(x) !== Number.isNaN(y)) return Number.isNaN(x) ? 1 : -1;
      return (Number.isNaN(x) ? 0 : x - y) || a.card.id - b.card.id;
    });
  const per = new Map<string, KindProject>();
  for (const r of rows) {
    const e = per.get(r.slug) ?? { slug: r.slug, name: r.name, icon: r.icon, count: 0 };
    e.count += 1;
    per.set(r.slug, e);
  }
  // the project with the most cards of this kind first (its avatar leads the stack)
  const projects = [...per.values()].sort((a, b) => b.count - a.count || a.slug.localeCompare(b.slug));
  return { kind, count: rows.length, projects, rows };
}

export function byKind(w: Waiting): Record<Kind, KindGroup> {
  return {
    ask: group("ask", w.projects, (c) => c.kind === "ask"),
    review: group("review", w.projects, (c) => c.kind !== "ask"),
    external: group("external", [...w.external, ...w.held], () => true),
    approved: group("approved", w.approved, () => true),
  };
}

// "4 to answer · gadgets, widgets" — a segment's accessible name and hover title
export const segmentLabel = (g: KindGroup) =>
  `${g.count} ${KIND_LABEL[g.kind]}${g.projects.length ? ` · ${g.projects.map((p) => p.slug).join(", ")}` : ""}`;

// the tab list's arrow keys (roving focus): ←/→ wrap, Home/End jump; anything else → null (not ours)
const STEP: Record<Kind, { next: Kind; prev: Kind }> = {
  ask: { next: "review", prev: "approved" },
  review: { next: "external", prev: "ask" },
  external: { next: "approved", prev: "review" },
  approved: { next: "ask", prev: "external" },
};
export function nextKind(current: Kind, key: string): Kind | null {
  if (key === "ArrowRight") return STEP[current].next;
  if (key === "ArrowLeft") return STEP[current].prev;
  if (key === "Home") return "ask";
  if (key === "End") return "approved";
  return null;
}

// the sheet's rows (↑/↓ move focus between them, no wrap; Home/End jump): the index to focus, or null (not ours)
export function nextRow(current: number, count: number, key: string): number | null {
  if (count === 0) return null;
  if (key === "ArrowDown") return current < 0 ? 0 : Math.min(current + 1, count - 1);
  if (key === "ArrowUp") return current < 0 ? count - 1 : Math.max(current - 1, 0);
  if (key === "Home") return 0;
  if (key === "End") return count - 1;
  return null;
}

// age of an ISO time against `at` (epoch seconds): 42s · 7m · 3h · 2d; unknown → "—" (never guessed)
export function age(iso: string | null, at: number): string {
  if (!iso) return "—";
  const t = Math.floor(Date.parse(iso) / 1000);
  if (Number.isNaN(t)) return "—";
  const d = Math.max(0, at - t);
  if (d < 60) return `${d}s`;
  if (d < 3600) return `${Math.floor(d / 60)}m`;
  if (d < 86400) return `${Math.floor(d / 3600)}h`;
  return `${Math.floor(d / 86400)}d`;
}

// an approved row's line (the tab already says approved): who carries it on and to where — "shop_lead
// merging" / "shop_lead → Deploy check". A row in the approved list without carried_on or an owner is a server bug: it
// throws, never reads as a guess
export function approvedLine(c: WaitingCard): string {
  const on = c.carried_on;
  if (!on || !c.owner_session) throw new Error(`card ${c.id}: approved row without its agent's next step`);
  return on.final ? `${c.owner_session} merging` : `${c.owner_session} → ${on.next_label}`;
}
