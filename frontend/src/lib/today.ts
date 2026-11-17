// The Today page's derivations, pure so they are testable: which repos want attention, what the section
// labels say, the year's facts beside the heatmap, the 7-day bars. A figure that is not known stays null (shown "—"),
// never 0.
import { repos } from "./tree";
import type { DailyCounts, DayStats, TodayData, TreeNode, WeekActivity } from "../types";

// ── what needs attention: the active repos with uncommitted / unpushed work, most first ────────────────────────────
export type Pending = { slug: string; n: number };
export type PendingList = {
  total: number; // repos with pending work over EVERY tracked repo (the server's count)
  repos: Pending[]; // the ones among the repos active in 7 days (the page's tree), most first
  rest: number; // total − repos.length: repos with pending work that are not in the active tree
};
export type Attention = { dirty: PendingList; unpushed: PendingList };

const list = (all: Pending[], total: number): PendingList => {
  const picked = all.filter((p) => p.n > 0).sort((a, b) => b.n - a.n || a.slug.localeCompare(b.slug));
  return { total, repos: picked, rest: total - picked.length };
};

export function attention(tree: TreeNode[], stats: TodayData["stats"]): Attention {
  const ps = repos(tree);
  return {
    dirty: list(
      ps.map((p) => ({ slug: p.slug, n: p.dirty })),
      stats.dirty,
    ),
    // unpushed null = no upstream: unknown, so not a repo "with unpushed commits"
    unpushed: list(
      ps.flatMap((p) => (p.unpushed == null ? [] : [{ slug: p.slug, n: p.unpushed }])),
      stats.unpushed,
    ),
  };
}

// the chips of a line: the first `fold`, and how many the fold hides
export function folded<T>(items: T[], fold: number, open: boolean): { shown: T[]; hidden: number } {
  if (open || items.length <= fold) return { shown: items, hidden: 0 };
  return { shown: items.slice(0, fold), hidden: items.length - fold };
}

// the unit of a pending line's total: it counts REPOS (the chips beside it count files / commits per repo)
export const repoUnit = (n: number) => (n === 1 ? "repo" : "repos");

// a slug's last path segment (the chip's text; the whole slug is its title)
export const leaf = (slug: string) => slug.slice(slug.lastIndexOf("/") + 1);

// ── section labels: numbers, no sentences ──────────────────────────────────────────────────────────────────────────
// "Today · 262 commits · 261 mine · 5 repos · latest 60": mine / repos only when the newest day row IS today (else
// not known → left out, never 0); "latest N" only when the list holds fewer commits than the day has.
export function commitsLabel(stats: TodayData["stats"], days: DayStats[], today: string, listed: number): string[] {
  const t = days[0]?.day === today ? days[0] : undefined;
  const out = [`${stats.commits_today} commit${stats.commits_today === 1 ? "" : "s"}`];
  if (t) out.push(`${t.mine} mine`, `${t.repos} repo${t.repos === 1 ? "" : "s"}`);
  if (listed < stats.commits_today) out.push(`latest ${listed}`);
  return out;
}

// "7 days · top 14 of 21 repos" when the list is cut, else "7 days · 14 repos"
export function weekLabel(rows: WeekActivity[], active7: number): string {
  return rows.length < active7
    ? `top ${rows.length} of ${active7} repos`
    : `${rows.length} repo${rows.length === 1 ? "" : "s"}`;
}

// ── 7-day bars: each repo's share of the busiest one, and my part of its bar ───────────────────────────────────────
export type WeekBar = { slug: string; commits: number; mine: number; pct: number; minePct: number };

export function weekBars(rows: WeekActivity[]): WeekBar[] {
  const max = Math.max(0, ...rows.map((r) => r.commits));
  return rows.map((r) => ({
    slug: r.project_slug,
    commits: r.commits,
    mine: r.mine,
    pct: max === 0 ? 0 : Math.round((r.commits * 100) / max),
    minePct: r.commits === 0 ? 0 : Math.round((r.mine * 100) / r.commits),
  }));
}

// ── the year beside the heatmap ────────────────────────────────────────────────────────────────────────────────────
const pad = (n: number) => String(n).padStart(2, "0");
export const localDay = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const back = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() - n);

export const YEAR_DAYS = 365;
export type YearFacts = {
  active: number; // days with ≥ 1 commit in the 365 ending today
  streak: number; // consecutive days with commits ending today — or yesterday while today has none yet
  best: { day: string; n: number } | null; // the busiest day (the newest on a tie); null = no commit in the year
};

export function yearFacts(counts: DailyCounts, today: Date): YearFacts {
  let active = 0;
  let best: YearFacts["best"] = null;
  for (let i = 0; i < YEAR_DAYS; i++) {
    const day = localDay(back(today, i));
    const n = counts[day] ?? 0;
    if (n > 0) active++;
    if (n > 0 && (!best || n > best.n)) best = { day, n };
  }
  let streak = 0;
  const from = (counts[localDay(today)] ?? 0) > 0 ? 0 : 1;
  for (let i = from; i < YEAR_DAYS && (counts[localDay(back(today, i))] ?? 0) > 0; i++) streak++;
  return { active, streak, best };
}

// ── the report block: today's reports, else the latest one; the head carries the count, the body no repeat of it ─
export function reportBlock<R>(today: string, reports: R[], latest: R | null): { parts: string[]; shown: R[] } {
  if (reports.length > 0) return { parts: [today, `${reports.length} today`], shown: reports };
  return latest ? { parts: [today, "0 today", "latest"], shown: [latest] } : { parts: [today, "0 today"], shown: [] };
}
