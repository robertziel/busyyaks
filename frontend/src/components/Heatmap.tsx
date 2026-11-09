// GitHub-style contribution graph: 53 weeks × 7 days ending today, five levels by quartile (lib/busyyaks/heatmap.rb, ported).
import { useLayoutEffect, useRef, type ReactNode } from "react";
import type { DailyCounts } from "../types";

const CELL = 11;
const GAP = 3;
const STEP = CELL + GAP;
const LABEL_W = 28;
const MONTH_H = 14;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad = (n: number) => String(n).padStart(2, "0");
const iso = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

export function yearTotal(counts: DailyCounts, today = new Date()): number {
  const from = iso(addDays(today, -364));
  let n = 0;
  for (const [d, c] of Object.entries(counts)) if (d >= from) n += c;
  return n;
}

export function Heatmap({ counts, today = new Date() }: { counts: DailyCounts; today?: Date }) {
  const start = addDays(today, -364 - today.getDay()); // a Sunday, so columns are whole weeks
  const days: Date[] = [];
  for (let d = start; d <= today; d = addDays(d, 1)) days.push(d);
  const weeks: Date[][] = [];
  for (let i = 0; i < days.length; i += 7) weeks.push(days.slice(i, i + 7));
  const max = Math.max(0, ...Object.values(counts));
  const w = LABEL_W + weeks.length * STEP;
  const h = MONTH_H + 7 * STEP;
  return (
    <svg
      className="heatmap"
      viewBox={`0 0 ${w} ${h}`}
      width={w}
      height={h}
      role="img"
      aria-label="Commits per day, last year"
    >
      {weeks.map((week, wi) => {
        const first = week.find((d) => d.getDate() === 1);
        if (!first || wi >= weeks.length - 2) return null;
        return (
          <text key={`m${wi}`} x={LABEL_W + wi * STEP} y={10}>
            {MONTHS[first.getMonth()]}
          </text>
        );
      })}
      {[
        [1, "Mon"],
        [3, "Wed"],
        [5, "Fri"],
      ].map(([i, t]) => (
        <text key={t} x={0} y={MONTH_H + Number(i) * STEP + 9}>
          {t}
        </text>
      ))}
      {weeks.map((week, wi) =>
        week.map((d) => {
          const n = counts[iso(d)] ?? 0;
          const lvl = n === 0 || max === 0 ? 0 : Math.min(Math.ceil((n / max) * 4), 4);
          return (
            <rect
              key={iso(d)}
              x={LABEL_W + wi * STEP}
              y={MONTH_H + d.getDay() * STEP}
              width={CELL}
              height={CELL}
              rx={2.5}
              className={`l${lvl}`}
            >
              <title>
                {n} commit{n === 1 ? "" : "s"} on {MONTHS[d.getMonth()]} {d.getDate()}, {d.getFullYear()}
              </title>
            </rect>
          );
        }),
      )}
    </svg>
  );
}

// The card around it: total, caption, legend; opens at today (its right end) when it has to scroll.
export function ContribCard({ counts, caption }: { counts: DailyCounts; caption: ReactNode }) {
  const wrap = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = wrap.current;
    if (el) el.scrollLeft = el.scrollWidth;
  }, [counts]);
  return (
    <section className="card contrib">
      <header>
        <b>{yearTotal(counts)}</b> <span className="muted">{caption}</span>
        <span className="legend muted">
          Less <i className="l0" />
          <i className="l1" />
          <i className="l2" />
          <i className="l3" />
          <i className="l4" /> More
        </span>
      </header>
      <div className="heatmap-wrap" ref={wrap}>
        <Heatmap counts={counts} />
      </div>
    </section>
  );
}
