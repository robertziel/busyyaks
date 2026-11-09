// The home page's per-day figures over the scan window: commits · mine · repos (scanned git logs) and
// merged PRs (GitHub search, the `github` collector) per local day, and the merged PRs themselves. A day the PR
// collection does not cover shows "—", never 0.
import type { CSSProperties } from "react";
import type { TileProps } from "./GraphTile";
import { Link } from "react-router-dom";
import { ago, num, projectPath } from "../lib/format";
import type { DayStats, MergedPr, PrStatus, TodayData } from "../types";

const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export function dayShort(iso: string, today: string): string {
  if (iso === today) return "Today";
  const m0 = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m0) return iso;
  const [y, m, d] = [Number(m0[1]), Number(m0[2]), Number(m0[3])];
  return `${DOW[new Date(y, m - 1, d).getDay()]} ${String(d).padStart(2, "0")}.${String(m).padStart(2, "0")}`;
}

const pct = (n: number, max: number) => ({ "--w": `${max === 0 ? 0 : Math.round((n * 100) / max)}%` }) as CSSProperties;

// total of a column, null when any day is unknown (a sum over unknown days is not a number)
export function total(days: DayStats[], k: "commits" | "mine" | "prs"): number | null {
  let s = 0;
  for (const d of days) {
    const v = d[k];
    if (v == null) return null;
    s += v;
  }
  return s;
}

export function DailyTable({ days, today }: { days: DayStats[]; today: string }) {
  const max = Math.max(0, ...days.map((d) => d.commits));
  return (
    <table className="data bars daily">
      <thead>
        <tr>
          <th>Day</th>
          <th>Commits</th>
          <th className="n" />
          <th className="n">Mine</th>
          <th className="n">Repos</th>
          <th className="n" title="your PRs merged (GitHub)">
            PRs
          </th>
        </tr>
      </thead>
      <tbody>
        {days.map((d) => (
          <tr key={d.day} className={d.commits === 0 && !d.prs ? "muted" : ""}>
            <td className="mono">{dayShort(d.day, today)}</td>
            <td className="bar">
              <span style={pct(d.commits, max)} />
            </td>
            <td className="n">{d.commits}</td>
            <td className="n">{d.mine}</td>
            <td className="n">{d.repos}</td>
            <td className={`n${d.prs ? " ok" : ""}`}>{num(d.prs)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <td>{days.length}d</td>
          <td />
          <td className="n">{num(total(days, "commits"))}</td>
          <td className="n">{num(total(days, "mine"))}</td>
          <td />
          <td className="n">{num(total(days, "prs"))}</td>
        </tr>
      </tfoot>
    </table>
  );
}

// the PR collection's state: never read · failed (reason + last good read) · read N ago
export function PrStatusLine({ status }: { status: PrStatus | null }) {
  if (!status)
    return (
      <p className="err pr-status">
        <i className="dot bad" /> merged PRs never read from GitHub (the github service has not finished a run)
      </p>
    );
  if (!status.ok)
    return (
      <p className="err pr-status">
        <i className="dot bad" /> GitHub PR read failed {ago(status.at)} ago: {status.error} · last good read{" "}
        {status.last_ok_at ? `${ago(status.last_ok_at)} ago` : "never"}
      </p>
    );
  return (
    <p className="muted pr-status">
      <i className="dot ok" /> GitHub · read {ago(status.at)} ago · since {status.since}
    </p>
  );
}

export function MergedPrs({ prs, total, fold = 12 }: { prs: MergedPr[]; total: number; fold?: number }) {
  if (prs.length === 0) return <p className="muted">0 merged PRs</p>;
  return (
    <ul className="merged-prs">
      {prs.slice(0, fold).map((p) => (
        <li key={`${p.repo}#${p.number}`}>
          {p.project_slug ? (
            <Link className="mpr-repo" to={projectPath(p.project_slug)} title={p.repo}>
              {p.project_slug}
            </Link>
          ) : (
            <span className="mpr-repo" title="not a tracked repo">
              {p.repo}
            </span>
          )}
          <a className="mpr-n mono" href={p.url} target="_blank" rel="noreferrer">
            #{p.number}
          </a>
          <span className="mpr-s" title={p.title}>
            {p.title}
          </span>
          <span className="mpr-t muted">{ago(p.merged_at)}</span>
        </li>
      ))}
      {total > fold && <li className="muted">+{total - fold}</li>}
    </ul>
  );
}

// The home page's figure tiles: today's value of each per-day column over its graph across the window
// (oldest first; a day the PR collection does not cover is a gap, never 0), and under it yesterday + the window's
// total ("—" when any day is unknown). `title` spells every day.
type Key = "commits" | "mine" | "repos" | "prs";
export function dayTiles(days: DayStats[], today: string, stats: TodayData["stats"]): TileProps[] {
  const asc = [...days].reverse();
  const t = days[0]?.day === today ? days[0] : undefined;
  const y = days[0]?.day === today ? days[1] : days[0];
  const tile = (label: string, k: Key, value: number | null | undefined, sum: string): TileProps => ({
    label,
    value: value ?? null,
    series: asc.map((d) => d[k]),
    title: asc.map((d) => `${dayShort(d.day, today)} ${num(d[k])}`).join(" · "),
    note: (
      <>
        <span className="k">yest</span> {num(y?.[k])} <span className="k">· {sum}</span>{" "}
        {k === "repos" ? stats.active7 : num(total(days, k))}
      </>
    ),
  });
  return [
    tile("Commits", "commits", stats.commits_today, `${days.length}d`),
    tile("Mine", "mine", t?.mine ?? null, `${days.length}d`),
    tile("Repos", "repos", t?.repos ?? null, "active 7d"),
    tile("PRs merged", "prs", stats.prs_today, `${days.length}d`),
  ];
}
