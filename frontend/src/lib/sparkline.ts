// The graph of a figure tile (`sparkline` / `markOf` / `placeMarks`, ported from an internal dashboard's
// Glass tiles): one sample per slot, oldest first. A null is a sample we could NOT take — the
// line BREAKS there (drawing it as 0 would claim we measured nothing), and a sample with a gap on both sides is a
// dot, so no measurement goes undrawn. The axis runs from 0 to `max` (else the window's peak, at least 1).

export const SPARK_W = 100;
export const SPARK_H = 24;

export type Series = (number | null | undefined)[];

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

export type Spark = {
  line: string; // runs of 2+ samples
  fill: string; // the area under each run
  lone: string; // single samples between gaps
  peak: number; // the window's highest sample (0 when none)
  top: number; // the axis' ceiling
  ys: (number | null)[]; // each sample's height as a fraction DOWN from the top of the axis (null = gap)
  stops: { offset: number; t: number }[]; // the gradient: each sample's value / top, a gap carrying the one before
  samples: string; // "1" a sample, "0" a gap, one per slot
};

export function spark(series: Series, max?: number): Spark {
  const cells = series.map((v) => (isNum(v) ? v : null));
  const n = cells.length;
  const nums = cells.filter(isNum);
  const peak = nums.length ? Math.max(...nums) : 0;
  const top = Math.max(max ?? 0, peak, 1);
  const x = (i: number) => (n > 1 ? (i * SPARK_W) / (n - 1) : SPARK_W);
  const down = (v: number) => 1 - Math.min(Math.max(v, 0), top) / top;
  const y = (v: number) => 1 + (SPARK_H - 2) * down(v); // 0 sits on the base
  const pt = (i: number) => `${x(i).toFixed(2)} ${y(cells[i] as number).toFixed(2)}`;
  let line = "";
  let fill = "";
  let lone = "";
  for (let i = 0; i < n; i++) {
    if (!isNum(cells[i]) || isNum(cells[i - 1])) continue; // i opens a run
    let j = i;
    while (isNum(cells[j + 1])) j++;
    if (j === i) {
      lone += `M${pt(i)}h0`;
      continue;
    }
    const run: string[] = [];
    for (let k = i; k <= j; k++) run.push(pt(k));
    line += `M${run.join("L")}`;
    fill += `M${x(i).toFixed(2)} ${SPARK_H}L${run.join("L")}L${x(j).toFixed(2)} ${SPARK_H}Z`;
  }
  let last = nums.length ? (nums[0] as number) / top : 0;
  const ts = cells.map((v) => (isNum(v) ? (last = v / top) : last));
  const stops = ts
    .map((t, i) => ({ offset: n > 1 ? i / (n - 1) : 0, t }))
    .filter((_, i) => !(ts[i] === ts[i - 1] && ts[i] === ts[i + 1])); // a stop between two of its own changes nothing
  return {
    line,
    fill,
    lone,
    peak,
    top,
    ys: cells.map((v) => (isNum(v) ? down(v) : null)),
    stops,
    samples: cells.map((v) => (isNum(v) ? "1" : "0")).join(""),
  };
}

// The quiet reference label: "max 262" at the peak's level. None for a graph with nothing above 0.
export function markOf(s: Spark): { text: string; level: number } | null {
  if (!(s.peak > 0)) return null;
  return { text: `max ${Math.round(s.peak)}`, level: 1 - Math.min(s.peak, s.top) / s.top };
}

// THE LABEL KEEPS OFF THE LINE (`placeMarks`, in the graph's own pixels): just under the level it names at
// the trailing end; if the line runs through that spot, the leading end; then above the level; then the graph's top
// and bottom edges. No clear spot → null (not drawn). `w`/`h` the graph's box, `mw`/`mh` the label's.
export function placeMark(
  ys: (number | null)[],
  level: number,
  w: number,
  h: number,
  mw: number,
  mh: number,
): { top: number; trailing: boolean } | null {
  const n = ys.length;
  const half = mh / 2;
  const clearance = 1.5;
  const width = Math.min(mw, w);
  if (!(w > 0) || n < 2 || h < 2 * half + 2) return null;
  const px = (f: number) => (h * (1 + (SPARK_H - 2) * f)) / SPARK_H;
  const step = w / (n - 1);
  const extent = (trailing: boolean): [number, number] | null => {
    const from = trailing ? w - width - step : -step;
    const to = trailing ? w + step : width + step;
    let lo = Infinity;
    let hi = -Infinity;
    ys.forEach((f, i) => {
      if (f == null || i * step < from || i * step > to) return;
      lo = Math.min(lo, px(f));
      hi = Math.max(hi, px(f));
    });
    return lo === Infinity ? null : [lo - clearance, hi + clearance];
  };
  const ends = [true, false].map((trailing) => ({ trailing, line: extent(trailing) }));
  const markY = px(level);
  for (const yc of [markY + half + 0.5, markY - half - 0.5, half, h - half]) {
    if (yc < half || yc > h - half) continue;
    const end = ends.find((e) => !(e.line && e.line[0] <= yc + half && e.line[1] >= yc - half));
    if (end) return { top: yc - half, trailing: end.trailing };
  }
  return null;
}

// A value's colour on the activity scale (a rate scale, grey → blue): --rate-rest at 0, --rate-mid halfway,
// --rate-high at the axis' top, mixed in oklch (the Glass style's scale space). CSS, so the active skin re-values it.
export const rateColour = (t: number) => {
  const c = Math.min(Math.max(isNum(t) ? t : 0, 0), 1);
  return c <= 0.5
    ? `color-mix(in oklch, var(--rate-rest), var(--rate-mid) ${Math.round(c * 200)}%)`
    : `color-mix(in oklch, var(--rate-mid), var(--rate-high) ${Math.round((c - 0.5) * 200)}%)`;
};
