// The Today page's compact blocks: section heads that carry numbers, the pending-work lines, the one-line
// commit log, the 7-day bars and the year's facts. What they show is derived in lib/today.ts.
import { useState, type CSSProperties, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { ago, at, projectPath } from "../lib/format";
import { folded, leaf, repoUnit, weekBars, YEAR_DAYS, type PendingList, type YearFacts } from "../lib/today";
import type { Commit, WeekActivity } from "../types";
import { CopySha } from "./Commits";

// A section's head: its name, its numbers (joined by ·), and whatever sits at the right end (a status, a link).
export function Head({ title, parts = [], children }: { title: string; parts?: string[]; children?: ReactNode }) {
  return (
    <header className="td-h">
      <h2>{title}</h2>
      {parts.map((p) => (
        <span key={p} className="td-h-n">
          {p}
        </span>
      ))}
      {children && <div className="td-h-r">{children}</div>}
    </header>
  );
}

// "uncommitted 69 · [repo 7] [repo 2] +3 · +62 not active 7d": the count over every tracked repo, then the active
// repos behind it (most first, folded), then how many of the count the active tree does not hold.
export function PendingLine({
  label,
  unit,
  list,
  fold,
}: {
  label: string;
  unit: string;
  list: PendingList;
  fold: number;
}) {
  const [open, setOpen] = useState(false);
  const { shown, hidden } = folded(list.repos, fold, open);
  return (
    <div className="td-pend">
      <span className="td-pend-k">
        {label} <b className={list.total > 0 ? "warn" : ""}>{list.total}</b> {repoUnit(list.total)}
      </span>
      <span className="td-chips">
        {shown.map((p) => (
          <Link key={p.slug} className="td-chip" to={projectPath(p.slug)} title={`${p.slug} · ${p.n} ${unit}`}>
            <span>{leaf(p.slug)}</span>
            <b>{p.n}</b>
          </Link>
        ))}
        {list.repos.length > fold && (
          <button
            type="button"
            className="td-more"
            aria-expanded={open}
            onClick={() => setOpen(!open)}
            aria-label={open ? "less" : `+${hidden} more repos`}
          >
            {open ? "less" : `+${hidden}`}
          </button>
        )}
        {list.rest > 0 && (
          <Link className="td-rest" to="/projects" title={`${list.rest} more repos, none active in 7 days`}>
            +{list.rest} not active 7d
          </Link>
        )}
      </span>
    </div>
  );
}

// One line per commit: age · repo · subject · (the author, when not you) · sha + copy. Folded after `fold`.
export function CommitLog({ commits, fold }: { commits: Commit[]; fold: number }) {
  const [open, setOpen] = useState(false);
  if (commits.length === 0) return null; // the section head already says "0 commits"
  const { shown, hidden } = folded(commits, fold, open);
  return (
    <div className="td-panel">
      <ol className="td-log">
        {shown.map((c) => (
          <li key={c.sha} className={c.mine ? "" : "other"}>
            <span className="td-log-t" title={at(c.committed_at)}>
              {ago(c.committed_at)}
            </span>
            <Link className="td-log-repo" to={projectPath(c.project_slug)} title={c.project_slug}>
              {leaf(c.project_slug)}
            </Link>
            <span className="td-log-s" title={`${c.subject}\n${c.author} <${c.email}>`}>
              {c.url ? (
                <a href={c.url} target="_blank" rel="noopener">
                  {c.subject}
                </a>
              ) : (
                c.subject
              )}
            </span>
            {!c.mine && <span className="td-log-who">{c.author}</span>}
            <span className="c-actions">
              <CopySha sha={c.sha} />
              {c.url ? (
                <a className="sha-btn" href={c.url} target="_blank" rel="noopener">
                  {c.sha.slice(0, 7)}
                </a>
              ) : (
                <span className="sha-btn">{c.sha.slice(0, 7)}</span>
              )}
            </span>
          </li>
        ))}
      </ol>
      {commits.length > fold && (
        <button type="button" className="td-fold" aria-expanded={open} onClick={() => setOpen(!open)}>
          {open ? "Show fewer" : `Show ${hidden} more`}
        </button>
      )}
    </div>
  );
}

// 7 days per repo: the bar = its share of the busiest repo, the solid part = your commits in it.
export function WeekBars({ rows }: { rows: WeekActivity[] }) {
  if (rows.length === 0) return <p className="muted td-none">0 commits in 7 days</p>;
  return (
    <ol className="td-week td-panel">
      {weekBars(rows).map((b) => (
        <li key={b.slug} title={`${b.slug} · ${b.commits} commits · ${b.mine} mine`}>
          <Link to={projectPath(b.slug)}>{b.slug}</Link>
          <span className="td-bar">
            <i style={{ "--w": `${b.pct}%`, "--m": `${b.minePct}%` } as CSSProperties} />
          </span>
          <b>{b.commits}</b>
        </li>
      ))}
    </ol>
  );
}

// The year's figures beside the heatmap.
export function YearFactList({ facts, all, repos }: { facts: YearFacts; all: number; repos: number }) {
  return (
    <dl className="td-facts">
      <div>
        <dt>active days</dt>
        <dd>
          {facts.active}
          <span>/{YEAR_DAYS}</span>
        </dd>
      </div>
      <div>
        <dt>streak</dt>
        <dd>
          {facts.streak}
          <span>d</span>
        </dd>
      </div>
      <div>
        <dt>best day</dt>
        <dd>
          {facts.best ? facts.best.n : "—"}
          {facts.best && <span> {facts.best.day}</span>}
        </dd>
      </div>
      <div>
        <dt>all commits</dt>
        <dd>
          {all}
          <span> · {repos} repos</span>
        </dd>
      </div>
    </dl>
  );
}
