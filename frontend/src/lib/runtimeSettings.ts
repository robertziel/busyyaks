// Settings → Runtime: the services' timing revision (GET /api/settings/runtime) as an editable draft and
// back, plus what the form shows about it: the keys grouped by service, a duration in words, each field's refusal,
// the watch period against the CI poll window, and why Save is off. The server (Busyyaks::RuntimeSettings) stays the
// validator — its refusal is shown verbatim, at the field it names; the checks here mirror its two rules (a whole
// number in min..max; the watch period below the window) so Save is off, with the reason, before a round trip.
// Pure: tested by runtimeSettings.test.ts.

export type Revision = { id: number; author: string; at: number };
export type RuntimeDoc = Record<string, number | string>;
export type RuntimeSettingsData = {
  revision: Revision;
  doc: RuntimeDoc;
  keys: Record<string, { env: string; about: string }>; // form order; env = the .env key it replaced
  min: number;
  max: number;
  history: Revision[]; // the newest 20
  revisions: number; // every revision kept
};
export type Draft = Record<string, string>;

export const toDraft = (data: RuntimeSettingsData): Draft =>
  Object.fromEntries(Object.keys(data.keys).map((k) => [k, data.doc[k] === undefined ? "" : String(data.doc[k])]));

export const fromDraft = (draft: Draft): RuntimeDoc =>
  Object.fromEntries(Object.entries(draft).map(([k, v]) => [k, /^\d+$/.test(v.trim()) ? Number(v.trim()) : v]));

export const sameDoc = (a: RuntimeDoc, b: RuntimeDoc): boolean => JSON.stringify(a) === JSON.stringify(b);

// the CI poll window (10 × github_ci_interval_seconds) and the notifier's watch period (the watch rounded up to whole
// deliver turns, RuntimeSettings.watch_period): shown beside the fields, the server refuses a period not below the window
export function watchWindow(doc: RuntimeDoc): { period: number; window: number } | null {
  const ci = doc.github_ci_interval_seconds;
  const watch = doc.notifier_watch_seconds;
  const every = doc.notifier_interval_seconds;
  if (typeof ci !== "number" || typeof watch !== "number" || typeof every !== "number") return null;
  if (every <= 0) return null;
  return { period: Math.ceil(watch / every) * every, window: 10 * ci };
}

// ── the form ─────────────────────────────────────────────────────────────────────────────────────────────────────

export type Field = { key: string; label: string; env: string };
export type Group = { service: string; fields: Field[] };

// The keys in the server's order, grouped by the service their `about` names ("scanner: seconds between repo scans" →
// service scanner, label "between repo scans"). An `about` naming no service is a group of its own, under no name.
export function groups(keys: RuntimeSettingsData["keys"]): Group[] {
  const out: Group[] = [];
  for (const [key, { env, about }] of Object.entries(keys)) {
    const m = /^([a-z][a-z0-9_ -]*):\s*(.+)$/i.exec(about);
    const service = m ? m[1]! : "";
    const label = (m ? m[2]! : about).replace(/^seconds\s+/, "");
    const last = out[out.length - 1];
    if (last && last.service === service && service !== "") last.fields.push({ key, label, env });
    else out.push({ service, fields: [{ key, label, env }] });
  }
  return out;
}

// 3600 → "1 h", 90 → "1 min 30 s", 86400 → "24 h": the two largest units that are not zero
export function human(seconds: number): string {
  const parts: [number, string][] = [
    [Math.floor(seconds / 3600), "h"],
    [Math.floor((seconds % 3600) / 60), "min"],
    [seconds % 60, "s"],
  ];
  const shown = parts.filter(([n]) => n > 0).slice(0, 2);
  return shown.length ? shown.map(([n, u]) => `${n} ${u}`).join(" ") : "0 s";
}

// why the server would refuse this field's text, or null
export function fieldRefusal(text: string, min: number, max: number): string | null {
  const v = text.trim();
  if (v === "") return "required";
  if (!/^\d+$/.test(v)) return "whole seconds";
  const n = Number(v);
  if (n < min || n > max) return `${min}–${max} s`;
  return null;
}

export const changedKeys = (draft: Draft, loaded: Draft): string[] =>
  Object.keys(draft).filter((k) => draft[k]!.trim() !== loaded[k]);

// The watch period against the CI poll window as a figure: `fill` and `mark` are shares of the bar (the longer of the
// two spans it): fill = the period, mark = where the window ends. ok = the server's rule, period < window.
export type WatchFigure = {
  period: number;
  window: number;
  ok: boolean;
  spare: number; // window − period: ≤ 0 = refused
  fill: number;
  mark: number;
};
export function watchFigure(doc: RuntimeDoc): WatchFigure | null {
  const ww = watchWindow(doc);
  if (!ww || ww.window <= 0) return null;
  const { period, window } = ww;
  const span = Math.max(period, window);
  return {
    period,
    window,
    ok: period < window,
    spare: window - period,
    fill: period / span,
    mark: window / span,
  };
}
// the fields the figure is made of → their part in it
export const WATCH_PARTS: Record<string, string> = {
  github_ci_interval_seconds: "window ÷ 10",
  notifier_interval_seconds: "turn",
  notifier_watch_seconds: "watch",
};

// why Save is off, or null: a newer revision than the form's base (`newer` = its id), nothing changed, a field the
// server would refuse, or the watch period not below the window
export function saveRefusal(draft: Draft, loaded: Draft, min: number, max: number, newer?: number): string | null {
  if (newer !== undefined) return `rev ${newer} is newer`;
  if (!changedKeys(draft, loaded).length) return "no changes";
  for (const [k, v] of Object.entries(draft)) {
    const why = fieldRefusal(v, min, max);
    if (why) return `${k}: ${why}`;
  }
  const fig = watchFigure(fromDraft(draft));
  if (fig && !fig.ok) return `watch ${fig.period} s ≥ window ${fig.window} s`;
  return null;
}

// the key a refusal names first ("scan_interval_seconds must be …" → that field shows it), or null (shown by Save)
export function refusedKey(message: string, keys: string[]): string | null {
  const m = /^(?:\d{3} · )?([a-z0-9_]+)\b/.exec(message);
  return m && keys.includes(m[1]!) ? m[1]! : null;
}

// Someone saved while the form was edited: the draft moved onto the newest revision. A key the form did not change
// takes the newest value; a changed key keeps the form's. A conflict = the other save changed that same key to
// something else than the form holds (theirs vs mine); both saves agreeing on a value is no conflict, and no change.
export type Conflict = { theirs: string; mine: string };
export function rebase(
  draft: Draft,
  loaded: Draft,
  newest: Draft,
): { draft: Draft; conflicts: Record<string, Conflict> } {
  const out: Draft = {};
  const conflicts: Record<string, Conflict> = {};
  for (const [k, theirs] of Object.entries(newest)) {
    const mine = draft[k];
    if (mine === undefined || mine.trim() === loaded[k]) {
      out[k] = theirs;
      continue;
    }
    out[k] = mine;
    if (theirs !== loaded[k] && theirs !== mine.trim()) conflicts[k] = { theirs, mine: mine.trim() };
  }
  return { draft: out, conflicts };
}
