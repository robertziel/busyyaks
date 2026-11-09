// A figure tile (the Glass palette's tile, ported from an internal dashboard): the label and the figure
// on one line, the graph under them with its quiet "max N" label, and ONE note slot that is drawn even when empty,
// so every tile of a band is the same height whatever the data. Tiles sit in a `.tiles` band (hairlines between
// them); `StatRow` is the label·value row under the band.
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { markOf, placeMark, rateColour, SPARK_H, SPARK_W, spark, type Series } from "../lib/sparkline";

let gid = 0;

export function Sparkline({ series, max }: { series: Series; max?: number }) {
  const s = spark(series, max);
  const id = useRef(`sg${++gid}`).current;
  const ink = `url(#${id})`;
  return (
    <svg
      className="sparkline"
      viewBox={`0 0 ${SPARK_W} ${SPARK_H}`}
      preserveAspectRatio="none"
      aria-hidden="true"
      data-samples={s.samples}
    >
      {s.stops.length > 0 && (
        <defs>
          <linearGradient id={id} gradientUnits="userSpaceOnUse" x1="0" y1="0" x2={SPARK_W} y2="0">
            {s.stops.map((st) => (
              <stop key={st.offset} offset={st.offset.toFixed(4)} style={{ stopColor: rateColour(st.t) }} />
            ))}
          </linearGradient>
        </defs>
      )}
      <line
        className="sparkline-base"
        x1="0"
        y1={SPARK_H - 0.25}
        x2={SPARK_W}
        y2={SPARK_H - 0.25}
        vectorEffect="non-scaling-stroke"
      />
      {s.fill && <path className="sparkline-area" d={s.fill} fill={ink} />}
      {s.line && (
        <path
          d={s.line}
          fill="none"
          stroke={ink}
          strokeWidth="1.5"
          strokeLinejoin="round"
          strokeLinecap="round"
          vectorEffect="non-scaling-stroke"
        />
      )}
      {s.lone && (
        <path
          d={s.lone}
          fill="none"
          stroke={ink}
          strokeWidth="3"
          strokeLinecap="round"
          vectorEffect="non-scaling-stroke"
        />
      )}
    </svg>
  );
}

// Places the label where the line is not, now and again whenever the graph's box resizes; returns the cleanup.
export function attachMark(g: HTMLElement, el: HTMLElement, ys: (number | null)[], level: number): () => void {
  const place = () => {
    const spot = placeMark(ys, level, g.clientWidth, g.clientHeight, el.offsetWidth, el.offsetHeight);
    el.classList.toggle("placed", !!spot);
    if (!spot) return;
    el.style.top = `${spot.top.toFixed(1)}px`;
    el.style.left = spot.trailing ? "auto" : "0";
    el.style.right = spot.trailing ? "0" : "auto";
  };
  place();
  const ro = new ResizeObserver(place);
  ro.observe(g);
  return () => ro.disconnect();
}

// The graph with its reference label, placed after layout where the line is not (and not drawn where no spot is clear).
function Graph({ series, max }: { series: Series; max?: number }) {
  const s = spark(series, max);
  const m = markOf(s);
  const box = useRef<HTMLDivElement>(null);
  const mark = useRef<HTMLSpanElement>(null);
  // The effect keys on values, not on this render's fresh arrays: the heights as JSON (exact for finite numbers, a gap
  // is null), the mark's level, and its text (the label's width moves the spot).
  const ys = JSON.stringify(s.ys);
  const level = m?.level;
  const text = m?.text;
  useLayoutEffect(() => {
    const g = box.current;
    const el = mark.current;
    if (!g || !el || level == null) return;
    return attachMark(g, el, JSON.parse(ys) as (number | null)[], level);
  }, [ys, level, text]);
  return (
    <div className="t-graph" ref={box}>
      <Sparkline series={series} max={max} />
      {m && (
        <span className="t-mark" ref={mark} aria-hidden="true">
          {m.text}
        </span>
      )}
    </div>
  );
}

export type TileProps = {
  label: string;
  value: number | null; // null → "—" (not known), never 0
  series: Series; // oldest first
  note?: ReactNode; // the one fragment under the graph; the slot is drawn even when empty
  title?: string; // the whole series in words, for hover
  max?: number;
};

export function GraphTile({ label, value, series, note, title, max }: TileProps) {
  const s = spark(series, max);
  const blank = value == null;
  const colour = blank ? undefined : rateColour(value / s.top);
  // a figure that changes while the page is open flashes once (a new key restarts the animation)
  const prev = useRef(value);
  const [bump, setBump] = useState(0);
  useEffect(() => {
    if (prev.current === value) return;
    if (prev.current != null && value != null) setBump((b) => b + 1);
    prev.current = value;
  }, [value]);
  return (
    <div className={`tile${blank ? " dim" : ""}`} title={title}>
      <div className="t-head">
        <span className="t-label">{label}</span>
        <b key={bump} className={`t-val${bump ? " bump" : ""}`} style={colour ? { color: colour } : undefined}>
          {blank ? "—" : value}
        </b>
      </div>
      <Graph series={series} max={max} />
      <div className="t-note">{note}</div>
    </div>
  );
}

export function Tiles({ children }: { children: ReactNode }) {
  return <div className="tiles">{children}</div>;
}

// THE ROW UNDER THE TILES: label·value pairs side by side, wrapping; `tone` colours a figure that wants attention.
export type Stat = { label: string; value: ReactNode; tone?: "warn" | "bad" | "ok"; title?: string };

export function StatRow({ stats }: { stats: Stat[] }) {
  return (
    <div className="tstats">
      {stats.map((s) => (
        <span key={s.label} className="tstat" title={s.title}>
          <span>{s.label}</span>
          <b className={s.tone ?? ""}>{s.value}</b>
        </span>
      ))}
    </div>
  );
}
