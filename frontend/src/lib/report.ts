// Report digest helpers: the author line, the figure changes and the counters shown on report cards and the report header.
import type { ReportDigest, ReportFigure } from "../types";

// "busyyaks-daily (sonnet + one sonnet agent per repo)" → name + detail; no parenthesis → detail null
export function authorParts(author: string): { name: string; detail: string | null } {
  const m = /^(.*?)\s*\((.+)\)\s*$/.exec(author);
  return m && m[1] && m[2] ? { name: m[1], detail: m[2] } : { name: author, detail: null };
}

export type Change = { dir: "up" | "down" | "flat"; feel: "good" | "bad" | ""; text: string };

// A figure's change vs the previous report; null when the figure has no prev (unknown, not zero).
export function figureChange(f: ReportFigure): Change | null {
  if (f.delta == null) return null;
  const n = Number(f.delta);
  if (!Number.isFinite(n)) return null;
  const dir = n > 0 ? "up" : n < 0 ? "down" : "flat";
  const feel = f.good == null || dir === "flat" ? "" : dir === f.good ? "good" : "bad";
  return { dir, feel, text: dir === "flat" ? "=" : `${dir === "up" ? "▲" : "▼"}${Math.abs(n)}` };
}

export type Counter = { key: string; n: number; label: string; tone: "bad" | "warn" | "neutral" };

// The non-zero counters of a digest, most urgent first.
export function digestCounters(d: ReportDigest): Counter[] {
  const total = d.actions.high + d.actions.med + d.actions.low;
  const all: Counter[] = [
    { key: "broken", n: d.broken, label: d.broken === 1 ? "broken block" : "broken blocks", tone: "bad" },
    { key: "needs", n: d.needs, label: "need you", tone: "warn" },
    { key: "high", n: d.actions.high, label: "high", tone: "bad" },
    { key: "actions", n: total, label: total === 1 ? "action" : "actions", tone: "neutral" },
    { key: "flags", n: d.flags, label: d.flags === 1 ? "flag" : "flags", tone: "neutral" },
    { key: "repos", n: d.repos, label: d.repos === 1 ? "repo" : "repos", tone: "neutral" },
  ];
  return all.filter((c) => c.n > 0);
}
