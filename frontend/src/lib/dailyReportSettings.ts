// Settings → Daily report: the daily report settings revision (GET /api/settings/daily-report) as an
// editable draft and back. The server (DailyReportConfig + the host's runner allowlist) is the only validator: what it
// refuses is shown verbatim; this only shapes the form. Pure: tested by dailyReportSettings.test.ts.

export type RunnerEntry = Record<string, string> & { type: string }; // config/busyyaks.yml daily_report_runners[i]
export type Runner = Record<string, string | number> & { type: string };
export type DailyDoc = {
  schedule: string;
  cutoff: string;
  probe_timeout: number;
  run_timeout: string;
  gateway: string;
  model: string;
  agent_model: string;
  context_length: number;
  runner: Runner;
};
export type Revision = { id: number; author: string; at: number };
export type DailyReportSettingsData = {
  revision: Revision | null; // null = never saved
  doc: DailyDoc | null;
  runners: RunnerEntry[]; // the host allowlist: what a runner may execute
  host_keys: Record<string, string[]>; // per runner type: the keys only the allowlist sets
  runner_keys: Record<string, string[]>; // per runner type: every key of a runner (beside type)
  history: Revision[]; // the newest 20
  revisions: number; // every revision kept
  error: string | null; // why the CURRENT settings do not run (none saved, a runner the host dropped), or null
};

// the top-level fields in form order; the integers are sent as numbers when they read as one
export const FIELDS = [
  ["schedule", "systemd OnCalendar of the tick, local time"],
  ["cutoff", "HH:MM: from then on a gateway that is down posts one NOT RUN report"],
  ["probe_timeout", "seconds for each gateway probe"],
  ["run_timeout", "wall-clock limit of one run (timeout(1): 90m)"],
  ["gateway", "OpenAI-compatible base URL (ends in /v1), the only provider"],
  ["model", "lead model id, or served"],
  ["agent_model", "child model id (one per active repo), or served"],
  ["context_length", "lead model context window, tokens"],
] as const;
export type Field = (typeof FIELDS)[number][0];
const INTEGER: readonly Field[] = ["probe_timeout", "context_length"];

export type Draft = {
  fields: Record<Field, string>;
  runner: number; // index into runners; -1 = none picked yet, or the saved runner matches none (shown, not selectable)
  saved: Runner | null; // the saved runner, for the -1 case
  extra: Record<string, string>; // the runner's page keys (runner_keys − host_keys), e.g. hermes max_children
};

const num = (v: string): string | number => (/^\d+$/.test(v.trim()) ? Number(v.trim()) : v);

// the runner's keys the page edits (the rest come from the allowlist entry)
export const pageKeys = (data: DailyReportSettingsData, type: string): string[] =>
  (data.runner_keys[type] ?? []).filter((k) => !(data.host_keys[type] ?? []).includes(k));

// the allowlist entry a runner equals on its type's host keys, or -1
export function runnerIndex(data: DailyReportSettingsData, r: Runner): number {
  const keys = data.host_keys[r.type] ?? [];
  return data.runners.findIndex((e) => e.type === r.type && keys.every((k) => e[k] === r[k]));
}

export function toDraft(data: DailyReportSettingsData): Draft {
  const d = data.doc;
  const fields = Object.fromEntries(FIELDS.map(([k]) => [k, d ? String(d[k]) : ""])) as Record<Field, string>;
  // never saved: no runner picked — the operator chooses one (Save waits for it), the code never picks for them
  if (!d) return { fields, runner: -1, saved: null, extra: {} };
  const at = runnerIndex(data, d.runner);
  return {
    fields,
    runner: at,
    saved: d.runner,
    extra: Object.fromEntries(pageKeys(data, d.runner.type).map((k) => [k, String(d.runner[k] ?? "")])),
  };
}

// a pick of another allowlist entry: the page keys of its type, the values kept where the key is the same
export function pickRunner(data: DailyReportSettingsData, draft: Draft, i: number): Draft {
  const type = data.runners[i]!.type;
  return {
    ...draft,
    runner: i,
    extra: Object.fromEntries(pageKeys(data, type).map((k) => [k, draft.extra[k] ?? ""])),
  };
}

export function fromDraft(data: DailyReportSettingsData, draft: Draft): DailyDoc {
  const base: Runner | null = draft.runner >= 0 ? { ...data.runners[draft.runner]! } : draft.saved;
  const runner = { ...(base ?? { type: "" }) } as Runner;
  for (const [k, v] of Object.entries(draft.extra)) runner[k] = num(v);
  const top = Object.fromEntries(
    FIELDS.map(([k]) => [k, INTEGER.includes(k) ? num(draft.fields[k]) : draft.fields[k]]),
  ) as Omit<DailyDoc, "runner">;
  return { ...top, runner };
}

export const entryLine = (e: RunnerEntry): string =>
  `${e.type}: ${Object.entries(e)
    .filter(([k]) => k !== "type")
    .map(([k, v]) => `${k} ${v}`)
    .join(" · ")}`;

// Save needs a runner: one picked from the allowlist, or the saved one kept as it is
export const hasRunner = (draft: Draft): boolean => draft.runner >= 0 || draft.saved !== null;

export const sameDoc = (a: DailyDoc | null, b: DailyDoc | null): boolean => JSON.stringify(a) === JSON.stringify(b);
