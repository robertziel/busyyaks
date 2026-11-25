// The first-run hello screen (/hello): GET /api/setup's shape, the launcher rows the Agents step edits, and
// the agent settings document they save (POST /api/settings/agents — the server validates, its refusal is shown
// verbatim). Pure: tested by hello.test.ts.
import type { AgentDoc, AgentSettingsData, AgentType, Invocation, Launcher, Model } from "./agentSettings";
import { invocationIndex } from "./agentSettings";

export type Check = { key: string; label: string; ok: boolean; detail: string };
export type SetupData = {
  completed: { author: string; at: number } | null;
  checks: Check[];
  projects: {
    host_root: string; // .env PROJECTS_ROOT
    mount: string; // .env PROJECTS_MOUNT
    roots: { path: string; prefix: string }[]; // config/busyyaks.yml roots
    search_depth: number;
    repos: number;
    sample: string[];
  };
  agents: AgentSettingsData;
  // Settings → Daily report's current revision as the host runs it (shown on Summary; edited on its own page)
  // saved: a revision exists (false = never set up)
  daily_report: {
    configured: boolean;
    saved: boolean;
    schedule: string | null;
    reason: string | null;
  };
  kinds: Record<string, string>; // engine launch kind → its harness label (config/harnesses.yml)
};

// The projects dir (card 532): .env PROJECTS_ROOT, changed by bin/launcher on the host.
// GET /api/setup/browse?path= — one host dir's subdirs for the picker (git = the subdir is a repo)
export type BrowseData = {
  path: string;
  parent: string | null;
  entries: { name: string; git: boolean }[];
  truncated: boolean;
  repos: number;
};
// POST /api/setup/projects-root {step: "plan"} → every check passed; plan_id must come back with the apply
export type RootPlan = {
  from: string;
  to: string;
  repos: number;
  roots: { path: string; host: string }[];
  trusted: { path: string; from: string; to: string }[];
  loses_trust: string[]; // repos the launcher's create made under the old dir: their folder trust stays there
  services: string[];
  plan_id: string;
};
// GET /api/setup/projects-root → the dir the launcher runs on + its last change (null: never changed here)
export type RootStatus = {
  current: string;
  applying: boolean;
  last: {
    state: "applying" | "done" | "failed" | "interrupted"; // interrupted: no apply runs and its record never finished
    note?: string;
    from: string;
    to: string;
    at: string;
    error?: string;
    rolled_back?: boolean;
    env: "new" | "restored" | "unknown"; // which .env is in place now (unknown: the record never said)
    log: string;
  } | null;
};
// a failed change in parts: the reason, which .env is in place (as recorded, never assumed), the log
export function failureParts(l: NonNullable<RootStatus["last"]>): { reason: string; env: string; log: string } {
  const env =
    l.env === "restored"
      ? `.env restored${l.rolled_back === false ? ", rollback compose failed too" : ""}`
      : l.env === "new"
        ? `.env still holds ${l.to}`
        : ".env state not recorded: check PROJECTS_ROOT in .env";
  return { reason: l.error ?? l.note ?? "reason not recorded", env, log: l.log };
}
// a host dir as the picker's breadcrumb: "/" then each segment with the dir it opens
export function crumbs(dir: string): { name: string; path: string }[] {
  const parts = dir.split("/").filter(Boolean);
  return [{ name: "/", path: "/" }, ...parts.map((name, i) => ({ name, path: `/${parts.slice(0, i + 1).join("/")}` }))];
}
export const parentPath = (dir: string) => dir.replace(/\/[^/]*\/?$/, "") || "/";
export const childPath = (dir: string, name: string) => (dir === "/" ? `/${name}` : `${dir}/${name}`);
// where an apply stands, from the status read (null = unreadable: the web is restarting)
export function applyPhase(s: RootStatus | null, to: string): "restarting" | "done" | "failed" | "applying" {
  if (!s) return "restarting";
  if (s.last && s.last.to === to && (s.last.state === "failed" || s.last.state === "interrupted")) return "failed";
  if (s.current === to && s.last?.state === "done") return "done";
  return "applying";
}

// GET /api/setup/harnesses: the agent CLIs the launcher found in the launch shell (bash -ic), joined with
// the host allowlist. allowed = indexes into agents.commands of the harness's kind; allow_line = the launch.commands
// item to add (null: no engine launch kind). commands[at] = each allowlisted command as that shell resolves it.
export type Harness = {
  key: string;
  label: string;
  command: string;
  install_url: string;
  kind: string | null;
  launch_args: string[];
  launchable: boolean;
  found: boolean;
  type: string | null; // file · function · alias · builtin · keyword
  path: string | null;
  version: string | null;
  version_error: string | null;
  allowed: number[];
  allow_line: string | null;
  allow_note: string | null; // why there is no line for a found harness (a shell function of a kind that needs a program)
};
// found null = unknown: the launcher did not resolve it (it read launch.commands before an edit)
export type Resolved = {
  at: number;
  found: boolean | null;
  type: string | null;
  path: string | null;
};
export type HarnessesData = {
  checked_at: number;
  elapsed_ms: number;
  shell: string;
  harnesses: Harness[];
  commands: Resolved[];
  allowlist_in_sync: boolean; // the launcher enforces the launch.commands the web read (false: restart both)
};

// the steps, in order; `?step=<key>` names one (any step reachable, deep-linkable); Git host is optional — nothing
// connected never blocks Summary or Done
export const STEP_KEYS = ["checks", "skin", "projects", "git", "agents", "summary"] as const;
export type StepKey = (typeof STEP_KEYS)[number];
export const STEP_LABELS: Record<StepKey, string> = {
  checks: "Checks",
  skin: "Skin",
  projects: "Projects",
  git: "Git host",
  agents: "Agents",
  summary: "Summary",
};

// the step to show: the one the URL names, else the landing — Checks on a first run, Summary on a reopen
export function stepFrom(param: string | null, completed: boolean): StepKey {
  if (param && (STEP_KEYS as readonly string[]).includes(param)) return param as StepKey;
  return completed ? "summary" : "checks";
}

// One harness card's state: what it says first (badge) and its tone. Glyph + word, colour second.
export type HarnessState = {
  key: string;
  badge: string;
  tone: "ok" | "warn" | "bad";
};

// resolved: the allowlisted commands as the launch shell resolves them — a harness program missing while an allowlisted
// command of its kind is found (a wrapper of its own name) is a warning, not "nothing runs"
export function harnessState(h: Harness, resolved: Resolved[] = []): HarnessState {
  if (!h.found) {
    if (h.allowed.some((i) => resolved.find((r) => r.at === i)?.found))
      return {
        key: "missing_runs",
        badge: "! not on PATH · allowed command found",
        tone: "warn",
      };
    return {
      key: h.allowed.length ? "missing_allowed" : "missing",
      badge: "✗ not found",
      tone: "bad",
    };
  }
  if (h.allow_note)
    return {
      key: "shell_unlaunchable",
      badge: `! shell ${h.type} · not launchable`,
      tone: "warn",
    };
  if (h.launchable && h.allowed.length === 0) return { key: "not_allowed", badge: "! not allowed", tone: "warn" };
  if (h.allowed.some((i) => resolved.find((r) => r.at === i)?.found === false))
    return {
      key: "allowed_missing",
      badge: "✓ found · allowed command ✗",
      tone: "warn",
    };
  if (h.version_error && h.type === "file") return { key: "version", badge: "✓ found · version ✗", tone: "warn" };
  return {
    key: h.type === "file" ? "found" : "shell",
    badge: "✓ found",
    tone: "ok",
  };
}

// the launchers in use whose command the launch shell does not find (a launch would fail): their keys
export function usedMissing(rows: Row[], resolved: Resolved[] | null): string[] {
  if (!resolved) return [];
  return rows
    .filter((r) => r.use && r.at >= 0 && resolved.find((c) => c.at === r.at)?.found === false)
    .map((r) => r.key);
}

// after an edit: the default stays when it is still in use, else the first launcher in use becomes it ("" = none)
export function keepDefault(rows: Row[], def: string): string {
  const used = rows.filter((r) => r.use).map((r) => r.key);
  return used.includes(def) ? def : (used[0] ?? "");
}

// the rows + default differ from what the current revision gives (an unsaved draft)
export function draftDirty(rows: Row[], def: string, base: Row[], baseDef: string): boolean {
  return def !== baseDef || JSON.stringify(rows) !== JSON.stringify(base);
}

// the harness summary in one line (Summary step, the agent prompt)
// The harness in one line, saying what its card says (Summary, the agent prompt): the version, then the allowlist state.
export function harnessLine(h: Harness, resolved: Resolved[] = []): string {
  const st = harnessState(h, resolved);
  if (st.key === "missing_runs") return `${h.command} not on PATH (allowed command found)`;
  if (!h.found) return `${h.command} not found`;
  const v = h.version ?? (h.type === "file" ? `version ✗ (${h.version_error})` : `shell ${h.type}`);
  const tail =
    st.key === "not_allowed"
      ? " (not allowed)"
      : st.key === "allowed_missing"
        ? " (allowed command ✗)"
        : st.key === "shell_unlaunchable"
          ? " (not launchable)"
          : h.launchable
            ? ""
            : " (not supported yet)";
  return `${h.command} ${v}${tail}`;
}

// The shell's <meta name="setup">: "pending" until someone finished the hello screen. `done` = finished in this tab.
export const setupPending = (meta: string | null, done: boolean): boolean => meta === "pending" && !done;

// One row of the Agents step: an existing launcher (its key fixed) or an allowlisted command not used yet.
// at = its index in the host allowlist (-1: the launcher is on none — it cannot run, and is dropped on save).
export type Row = {
  key: string;
  label: string;
  at: number;
  use: boolean;
  existing: boolean;
};

const slug = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "_")
    .replace(/^[^a-z]+|_+$/g, "") || "launcher";

export function rowsFrom(doc: AgentDoc, commands: Invocation[]): Row[] {
  const rows: Row[] = doc.launchers.map((l) => {
    const at = invocationIndex(commands, l);
    return { key: l.key, label: l.label, at, use: at >= 0, existing: true };
  });
  const taken = new Set(rows.map((r) => r.key));
  commands.forEach((c, at) => {
    if (rows.some((r) => r.at === at)) return;
    let key = slug(c.command);
    for (let n = 2; taken.has(key); n++) key = `${slug(c.command)}_${n}`;
    taken.add(key);
    rows.push({ key, label: c.command, at, use: false, existing: false });
  });
  return rows;
}

// The default launcher today: the lead's first one (its Launch menu's first entry), else the first launcher in use.
export function defaultFrom(doc: AgentDoc, rows: Row[]): string {
  const used = rows.filter((r) => r.use).map((r) => r.key);
  const lead = doc.agent_types.find((t) => t.key === "lead") ?? doc.agent_types[0];
  const pick = [lead?.launchers[0]].find((k): k is string => !!k && used.includes(k));
  return pick ?? used[0] ?? "";
}

// What is wrong with the rows before anything is sent (the server checks the rest); null = fine.
export function rowsError(rows: Row[], def: string): string | null {
  const used = rows.filter((r) => r.use);
  if (used.length === 0) return "pick at least one command";
  const keys = used.map((r) => r.key.trim());
  if (keys.some((k) => !/^[a-z][a-z0-9_-]{0,39}$/.test(k)))
    return "a key starts with a-z, then a-z 0-9 _ - (40 at most)";
  if (new Set(keys).size !== keys.length) return "two launchers share a key";
  if (used.some((r) => r.label.trim() === "")) return "every launcher needs a label";
  if (!keys.includes(def)) return "pick the default launcher";
  return null;
}

function modelFor(m: Model, keys: string[]): Model {
  if (m === null || typeof m === "string") return m; // one model (or Claude Code's own) for every launcher: kept
  const out = Object.fromEntries(keys.map((k) => [k, m[k] ?? null]));
  return Object.values(out).every((v) => v === null) ? null : out;
}

// The rows + the default → the new agent settings. Every type keeps the launchers it ran that are still in use, gets
// the newly added ones, and runs the default first (the Launch menu's first entry). Everything else of a type (prompt,
// caps, takes, the lead it runs under) is kept. Nothing picks a launcher at a start (lead-first boards): the
// Launch bar names one, a session under a lead runs the lead's.
export function applyRows(doc: AgentDoc, commands: Invocation[], rows: Row[], def: string): AgentDoc {
  const used = rows.filter((r) => r.use && r.at >= 0);
  const launchers: Launcher[] = used.map((r) => {
    const c = commands[r.at]!;
    return {
      key: r.key.trim(),
      label: r.label.trim(),
      kind: c.kind,
      command: c.command,
      args: [...c.args],
      via_shell: c.via_shell,
    };
  });
  const keys = launchers.map((l) => l.key);
  const added = used.filter((r) => !r.existing).map((r) => r.key.trim());
  const agent_types: AgentType[] = doc.agent_types.map((t) => {
    const kept = t.launchers.filter((k) => keys.includes(k) && k !== def);
    const ls = [def, ...kept, ...added.filter((k) => k !== def && !kept.includes(k))];
    return { ...t, launchers: ls, model: modelFor(t.model, ls) };
  });
  return { launchers, agent_types };
}

// after an edit of config/busyyaks.yml launch.commands: the launcher and the web both read it at their start
export const RESTART_BOTH = ["deploy/install-launcher.sh", "docker compose restart web"] as const;

// The note on every step: what to paste into your own agent (Claude Code, hermes, …) so it sets busyyaks up for you
// on the host — the parts the dashboard cannot write. harnesses: the detection result, or why it is unavailable.
export function agentPrompt(
  p: SetupData["projects"],
  commands: Invocation[],
  origin: string,
  harnesses: { data: HarnessesData } | { error: string } | null = null,
): string {
  const cmds = commands.map((c) => [c.command, ...c.args].join(" ")).join(", ");
  let found = "";
  let addCount = 0;
  if (harnesses && "error" in harnesses)
    found = ` Harness check unavailable: ${harnesses.error}. Start the launcher first (deploy/install-launcher.sh).`;
  else if (harnesses) {
    const hs = harnesses.data.harnesses;
    const add = hs.filter((h) => h.found && h.launchable && h.allowed.length === 0 && h.allow_line);
    addCount = add.length;
    const missing = hs.filter((h) => !h.found);
    found =
      ` Harnesses on this host: ${hs.map((h) => harnessLine(h, harnesses.data.commands)).join(", ")}.` +
      (missing.length
        ? ` Install if I want them: ${missing.map((h) => `${h.command} ${h.install_url}`).join(", ")}.`
        : "") +
      (add.length ? ` Add exactly: ${add.map((h) => h.allow_line).join(" ")}.` : "");
  }
  const step1 =
    p.repos === 0
      ? `1. Projects: .env PROJECTS_ROOT is ${p.host_root} and holds no git repo. Point it at the folder that holds my git repos, then \`docker compose up -d\`.`
      : `1. Projects: PROJECTS_ROOT ${p.host_root} holds ${p.repos} repos — leave it.`;
  return [
    `Set up busyyaks for me (the dashboard at ${origin}). Read its README.md and docs/DEPLOY.md first.`,
    step1,
    `2. Agent commands: config/busyyaks.yml launch.commands allows ${cmds || "none"}.${found} ${addCount ? "Ask me before adding anything else" : "Add the agent CLIs I use (claude, hermes, my shell functions — ask me which)"}, then restart both: ${RESTART_BOTH.join(" && ")}.`,
    `3. Tell me what you changed; I pick the launchers and the default on the hello screen.`,
  ].join("\n");
}

// What a save changes per agent type: its launcher list (the Launch menu order), before → after. Shown beside Save so
// no type is rewritten unseen; an unchanged type is not listed.
// under: the lead type it runs under (its sessions run that lead's launcher, whatever the list says), or null
export type TypeChange = {
  type: string;
  label: string;
  launchers: [string[], string[]];
  under: string | null;
};

// Types that run under a lead (worker, sub team) are listed too, with `under`: their sessions run the lead's
// launcher whatever their list says, so the page shows them as following it and does not count them.
export function typeChanges(before: AgentDoc, after: AgentDoc): TypeChange[] {
  return after.agent_types.flatMap((t) => {
    const was = before.agent_types.find((b) => b.key === t.key);
    if (!was) return [];
    const ls: [string[], string[]] = [was.launchers, t.launchers];
    return ls[0].join(",") === ls[1].join(",")
      ? []
      : [
          {
            type: t.key,
            label: t.label,
            launchers: ls,
            under: t.under ?? null,
          },
        ];
  });
}
