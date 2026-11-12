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
};

// The shell's <meta name="setup">: "pending" until someone finished the hello screen. `done` = finished in this tab.
export const setupPending = (meta: string | null, done: boolean): boolean => meta === "pending" && !done;

// One row of the Agents step: an existing launcher (its key fixed) or an allowlisted command not used yet.
// at = its index in the host allowlist (-1: the launcher is on none — it cannot run, and is dropped on save).
export type Row = { key: string; label: string; at: number; use: boolean; existing: boolean };

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

// The default launcher today: the lead's spawn launcher, else its first one, else the first launcher in use.
export function defaultFrom(doc: AgentDoc, rows: Row[]): string {
  const used = rows.filter((r) => r.use).map((r) => r.key);
  const lead = doc.agent_types.find((t) => t.key === "lead") ?? doc.agent_types[0];
  const pick = [lead?.spawn_launcher, lead?.launchers[0]].find((k): k is string => !!k && used.includes(k));
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
// the newly added ones, and runs the default first (the Launch menu's first entry) — as its spawn launcher when it has
// several (or named one before). Everything else of a type (prompt, caps, takes, follows) is kept.
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
    const out: AgentType = { ...t, launchers: ls, model: modelFor(t.model, ls) };
    // the spawn launcher only matters with a choice to make: several launchers, or one the type already named. A type
    // running its one launcher with none set keeps none (the engine runs its only launcher) — an untouched page saves
    // exactly what is stored
    if (ls.length > 1 || t.spawn_launcher) out.spawn_launcher = def;
    else delete out.spawn_launcher;
    return out;
  });
  return { launchers, agent_types };
}

// The note on every step: what to paste into your own agent (Claude Code, hermes, …) so it sets busyyaks up for you
// on the host — the parts the dashboard cannot write.
export function agentPrompt(p: SetupData["projects"], commands: Invocation[], origin: string): string {
  const cmds = commands.map((c) => [c.command, ...c.args].join(" ")).join(", ");
  return [
    `Set up busyyaks for me (the dashboard at ${origin}). Read its README.md and docs/DEPLOY.md first.`,
    `1. Projects: .env PROJECTS_ROOT is ${p.host_root} (${p.repos} repos found). Point it at the folder that holds my git repos, then \`docker compose up -d\`.`,
    `2. Agent commands: config/busyyaks.yml launch.commands allows ${cmds || "none"}. Add the agent CLIs I use (claude, hermes, my shell functions — ask me which), then restart the launcher (deploy/install-launcher.sh).`,
    `3. Tell me what you changed; I pick the launchers and the default on the hello screen.`,
  ].join("\n");
}

// What a save changes per agent type: its launcher list (the Launch menu order) and its spawn launcher, before → after.
// Shown beside Save so no type is rewritten unseen; an unchanged type is not listed.
export type TypeChange = { type: string; label: string; launchers: [string[], string[]]; spawn: [string, string] };

export function typeChanges(before: AgentDoc, after: AgentDoc): TypeChange[] {
  return after.agent_types.flatMap((t) => {
    const was = before.agent_types.find((b) => b.key === t.key);
    if (!was) return [];
    const ls: [string[], string[]] = [was.launchers, t.launchers];
    const spawn: [string, string] = [was.spawn_launcher ?? "", t.spawn_launcher ?? ""];
    const same = ls[0].join(",") === ls[1].join(",") && spawn[0] === spawn[1];
    return same ? [] : [{ type: t.key, label: t.label, launchers: ls, spawn }];
  });
}
