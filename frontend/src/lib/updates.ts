// Settings → Updates (card 536): the launcher's `update` status (GET /api/settings/update) turned into what the page
// and the settings cog show. Nothing is guessed: no check yet → no notice, a failed check is said with its time.

export type Target = {
  name?: string;
  sha?: string;
  version?: string;
  state: "current" | "available" | "ahead" | "diverged" | "none";
  behind?: number;
};

export type Check = {
  remote: string;
  // the URL git fetches from (`git ls-remote --get-url`): whoever can push there runs code here on Update
  url: string;
  channel: "tags" | "branch";
  checked_at: string;
  head: { sha: string; branch: string | null; describe: string };
  dirty: string[];
  tag: Target;
  branch: Target;
  ignored_tags: string[];
  available: boolean;
};

export type UpdateRecord = {
  // starting = the launcher spawned it; interrupted = the launcher found it starting / running with no update alive
  state: "starting" | "running" | "done" | "failed" | "interrupted" | "unreadable";
  step?: string | null;
  mode?: "tags" | "branch";
  from?: string;
  to?: string;
  name?: string;
  behind?: number;
  backup?: string;
  log?: string | null;
  error?: string;
  started_at?: string;
  done_at?: string;
};

export type UpdateStatus = {
  settings: {
    remote: string;
    branch: string;
    tags: string;
    channel: "tags" | "branch";
    check_minutes: number;
  };
  check: Check | null;
  checking: boolean;
  check_error: { at: string; error: string } | null;
  running: boolean;
  last: UpdateRecord | null;
};

export const STEPS = ["check", "checkout", "setup", "build", "backup", "up", "launcher", "status"] as const;
export const STEP_LABEL: Record<(typeof STEPS)[number], string> = {
  check: "check",
  backup: "back up DB",
  checkout: "checkout",
  setup: "bin/setup",
  build: "docker build",
  up: "compose up",
  launcher: "launcher",
  status: "status",
};

export const short = (sha: string | undefined) => (sha ? sha.slice(0, 7) : "—");

// the cog's notice: only a check that says the channel's target is a fast-forward away
export function notice(s: UpdateStatus | undefined): string | null {
  const c = s?.check;
  if (!c?.available) return null;
  if (c.channel === "tags") return `${c.tag.name ?? "tag"} available`;
  return `${c.branch.name ?? "branch"} +${c.branch.behind ?? 0}`;
}

export type Row = {
  mode: "tags" | "branch";
  label: string;
  name: string;
  sha: string | undefined;
  state: Target["state"];
  detail: string;
  // why Update is off, or null (it may run)
  blocked: string | null;
};

const STATE_TEXT: Record<Target["state"], string> = {
  current: "current",
  available: "available",
  ahead: "checkout is ahead",
  diverged: "diverged",
  none: "no version tag",
};

// one row per target, with the reason its Update button is off
export function rows(s: UpdateStatus): Row[] {
  const c = s.check;
  if (!c) return [];
  const onOther = c.head.branch && c.head.branch !== s.settings.branch ? c.head.branch : null;
  const make = (mode: "tags" | "branch", t: Target, label: string): Row => {
    const behind = t.state === "available" || t.state === "diverged" ? ` · ${t.behind ?? 0} commits` : "";
    let blocked: string | null = null;
    if (s.running)
      blocked = "an update is running"; // the lock's word, never a record left behind
    else if (t.state !== "available") blocked = STATE_TEXT[t.state];
    else if (c.dirty.length) blocked = `${c.dirty.length} tracked file${c.dirty.length === 1 ? "" : "s"} changed`;
    else if (onOther) blocked = `checkout on ${onOther}, updates follow ${s.settings.branch}`;
    return {
      mode,
      label,
      name: t.name ?? "—",
      sha: t.sha,
      state: t.state,
      detail: `${STATE_TEXT[t.state]}${behind}`,
      blocked,
    };
  };
  return [
    make("tags", c.tag, `newest ${s.settings.tags}`),
    make("branch", c.branch, `${c.remote}/${s.settings.branch}`),
  ];
}

export type Progress = {
  step: string;
  index: number;
  total: number;
  state: UpdateRecord["state"];
};

// the record's step as n / total (a done update is total / total)
export function progress(r: UpdateRecord | null): Progress | null {
  if (!r) return null;
  const total = STEPS.length;
  if (r.state === "done") return { step: "done", index: total, total, state: r.state };
  const i = STEPS.indexOf((r.step ?? "check") as (typeof STEPS)[number]);
  return {
    step: r.step ?? "check",
    index: i < 0 ? 0 : i,
    total,
    state: r.state,
  };
}

// the page polls fast while an update runs or the web is coming back, slow otherwise
export const pollEvery = (s: UpdateStatus | undefined, down: boolean) =>
  down || s?.running || s?.last?.state === "starting" || s?.checking ? 3000 : 60000;
