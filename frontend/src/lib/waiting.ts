// The "waiting for you" widget's data (GET /api/waiting, the engine's Api#waiting) and the pure bits the view shows.
import type { LaunchFailure } from "../vendor/agents_kanban";
import { projectPath } from "./format";

// kind: "ask" = flagged needs_operator (a question, in whatever column) · "review" = in a gate column (work to check, a
// PR to merge) · "blocked" = flagged blocked_external · else the column key
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
  owner_session: string | null;
};
export type WaitingProject = { slug: string; icon: string | null; count: number; cards: WaitingCard[] };
// launch_failures: the sessions whose start failed in the last day (a launch or a spawn: claude never came up) — the
// layout's LaunchFailureAlert opens a modal for the ones this viewer has not dismissed
export type Waiting = {
  waiting_columns: string[];
  total: number;
  projects: WaitingProject[];
  launch_failures: LaunchFailure[];
};

export const cardHref = (slug: string, id: number) => `${projectPath(slug)}?tab=board&card=${id}`;

// "3 waiting"
export const pillTotal = (w: Waiting) => `${w.total} waiting`;

// The round project bubbles on the pill, as the agents sidebar colours them: "ask" (needs input, red) ·
// "review" (a PR to merge, amber) · "other". Ordered by importance, then by the latest card's time — left to right,
// so the most important and most recent always sits on the right. An unknown time counts as the oldest.
export type BubbleLevel = "ask" | "review" | "other";
const RANK: Record<BubbleLevel, number> = { other: 0, review: 1, ask: 2 };
// the badge: how many cards of the bubble's top status (the tooltip has every count)
export const topCount = (b: { level: BubbleLevel; asks: number; reviews: number; others: number }) =>
  b.level === "ask" ? b.asks : b.level === "review" ? b.reviews : b.others;
export type Bubble = {
  slug: string;
  name: string;
  icon: string | null;
  count: number;
  asks: number;
  reviews: number;
  others: number;
  level: BubbleLevel;
  latest: number | null;
  title: string;
};

// The colour of each status, by what it asks of the operator: needs input = red (an agent is stopped on
// you) · PR to merge = amber (work done, waiting for your check) · any other waiting column = neutral. CSS tokens only.
export const LEVEL_COLOR: Record<BubbleLevel, string> = {
  ask: "var(--ww-c-ask)",
  review: "var(--ww-c-review)",
  other: "var(--ww-c-other)",
};
export const LEVEL_LABEL: Record<BubbleLevel, string> = { ask: "needs input", review: "to merge", other: "other" };

// A multicolour ring: one conic segment per status, sized by count, most important first from 12 o'clock, a 2° gap
// between segments (a mixed ring reads as parts without its colours). "needs input" never shrinks below 20 % of a mixed
// ring, so one question among many merges is still seen (colour critic).
const GAP = 100 / 180; // 2° in %
export function ring(counts: { asks: number; reviews: number; others: number }): string {
  const parts: [BubbleLevel, number][] = (
    [
      ["ask", counts.asks],
      ["review", counts.reviews],
      ["other", counts.others],
    ] as [BubbleLevel, number][]
  ).filter(([, n]) => n > 0);
  const total = parts.reduce((a, [, n]) => a + n, 0);
  if (!total) return LEVEL_COLOR.other;
  const only = parts.length === 1 ? parts[0] : undefined;
  if (only) return LEVEL_COLOR[only[0]];
  // shares in %, ask floored at 20 and the rest scaled into what is left
  const askShare = counts.asks ? Math.max((counts.asks / total) * 100, 20) : 0;
  const restTotal = total - counts.asks;
  const share = (lv: BubbleLevel, n: number) => (lv === "ask" ? askShare : (n / restTotal) * (100 - askShare));
  let at = 0;
  const stops = parts.flatMap(([lv, n]) => {
    const from = at;
    at += share(lv, n);
    return [
      `${LEVEL_COLOR[lv]} ${from.toFixed(2)}% ${(at - GAP).toFixed(2)}%`,
      `transparent ${(at - GAP).toFixed(2)}% ${at.toFixed(2)}%`,
    ];
  });
  return `conic-gradient(${stops.join(", ")})`;
}

export const totals = (w: Waiting) => {
  const cards = w.projects.flatMap((p) => p.cards);
  const asks = cards.filter((c) => c.kind === "ask").length;
  const reviews = cards.filter((c) => c.kind === "review").length;
  return { asks, reviews, others: cards.length - asks - reviews };
};

export function bubbles(w: Waiting): Bubble[] {
  return w.projects
    .map((p) => {
      const asks = p.cards.filter((c) => c.kind === "ask").length;
      const reviews = p.cards.filter((c) => c.kind === "review").length;
      const level: BubbleLevel = asks > 0 ? "ask" : reviews > 0 ? "review" : "other";
      const times = p.cards.map((c) => (c.since ? Date.parse(c.since) : NaN)).filter((t) => !Number.isNaN(t));
      const latest = times.length ? Math.max(...times) : null;
      const name = p.slug.split("/").pop() || p.slug;
      const parts = [
        asks > 0 && `${asks} needs input`,
        reviews > 0 && `${reviews} to merge`,
        p.count - asks - reviews > 0 && `${p.count - asks - reviews} other`,
      ].filter(Boolean);
      return {
        slug: p.slug,
        name,
        icon: p.icon,
        count: p.count,
        asks,
        reviews,
        others: p.count - asks - reviews,
        level,
        latest,
        title: `${p.slug} · ${parts.join(" · ")}`,
      };
    })
    .sort(
      (a, b) =>
        RANK[a.level] - RANK[b.level] ||
        (a.latest ?? -Infinity) - (b.latest ?? -Infinity) ||
        a.slug.localeCompare(b.slug),
    );
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
