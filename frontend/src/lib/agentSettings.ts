// Settings → Agents & launchers: the agent settings revision (GET /api/settings/agents) as an editable
// draft and back. The server (the engine + the host allowlist) is the only validator: what it refuses is shown
// verbatim; this only shapes the form. Pure: tested by agentSettings.test.ts.

// kind = the CLI family the command is (the engine's Launch::KINDS): how the model, the prompt and the session reach it
export type Launcher = {
  key: string;
  label: string;
  kind: string;
  command: string;
  args: string[];
  via_shell: boolean;
};
export type Model = string | null | Record<string, string | null>;
export type AgentType = {
  key: string;
  label: string;
  launchers: string[];
  model: Model;
  prompt: string | null;
  agent_name: string;
  session_name: string;
  takes: string[];
  max: number | null;
  max_per_project: number | null;
  spawns_for?: string[];
  launcher_follows?: string | null;
  spawn_launcher?: string | null;
};
// one host-allowlisted invocation: a launcher must equal one of them (its key and label are the dashboard's)
export type Invocation = { kind: string; command: string; args: string[]; via_shell: boolean };
export type AgentDoc = { launchers: Launcher[]; agent_types: AgentType[] };
export type Revision = { id: number; author: string; at: number };
export type PreviewRow = { type: string; launcher: string; model: string | null; argv: string[] };
export type AgentSettingsData = {
  revision: Revision;
  doc: AgentDoc;
  commands: Invocation[]; // the host allowlist (config/busyyaks.yml launch.commands): what a launcher may be
  history: Revision[];
  preview: PreviewRow[];
  error: string | null; // why the CURRENT revision does not run, or null
};

// the engine's FIXED column types (agents_kanban ColumnTypes): what `takes` / `spawns_for` name
export const COLUMN_TYPES = ["parked", "queued", "working", "review", "gate", "done", "cancelled"] as const;

// In the form a type's model is always one field per launcher it runs ("" = Claude Code's own choice).
export type TypeDraft = Omit<AgentType, "model" | "prompt" | "spawns_for" | "launcher_follows" | "spawn_launcher"> & {
  models: Record<string, string>;
  hasPrompt: boolean;
  prompt: string;
  spawns_for: string[];
  launcher_follows: string; // "" = none
  spawn_launcher: string; // "" = none
};
export type Draft = { launchers: Launcher[]; types: TypeDraft[] };

const modelOf = (m: Model, launcher: string): string => {
  if (m === null) return "";
  if (typeof m === "string") return m;
  return m[launcher] ?? "";
};

export function toDraft(doc: AgentDoc): Draft {
  return {
    launchers: doc.launchers.map((l) => ({ ...l, args: [...l.args] })),
    types: doc.agent_types.map((t) => ({
      key: t.key,
      label: t.label,
      launchers: [...t.launchers],
      models: Object.fromEntries(t.launchers.map((l) => [l, modelOf(t.model, l)])),
      hasPrompt: t.prompt !== null,
      prompt: t.prompt ?? "",
      agent_name: t.agent_name,
      session_name: t.session_name,
      takes: [...t.takes],
      max: t.max,
      max_per_project: t.max_per_project,
      spawns_for: [...(t.spawns_for ?? [])],
      launcher_follows: t.launcher_follows ?? "",
      spawn_launcher: t.spawn_launcher ?? "",
    })),
  };
}

// null when no launcher sets one; else a map naming exactly the type's launchers (the engine's rule)
function modelFrom(t: TypeDraft): Model {
  const vals = t.launchers.map((l) => (t.models[l] ?? "").trim());
  if (vals.every((v) => v === "")) return null;
  return Object.fromEntries(t.launchers.map((l, i) => [l, vals[i] === "" ? null : vals[i]!]));
}

export function fromDraft(d: Draft): AgentDoc {
  return {
    launchers: d.launchers.map((l) => ({
      key: l.key.trim(),
      label: l.label.trim(),
      kind: l.kind,
      command: l.command.trim(),
      args: [...l.args],
      via_shell: l.via_shell,
    })),
    agent_types: d.types.map((t) => {
      const out: AgentType = {
        key: t.key.trim(),
        label: t.label.trim(),
        launchers: [...t.launchers],
        model: modelFrom(t),
        prompt: t.hasPrompt ? t.prompt : null,
        agent_name: t.agent_name,
        session_name: t.session_name,
        takes: [...t.takes],
        max: t.max,
        max_per_project: t.max_per_project,
      };
      if (t.spawns_for.length) out.spawns_for = [...t.spawns_for];
      if (t.launcher_follows) out.launcher_follows = t.launcher_follows;
      if (t.spawn_launcher) out.spawn_launcher = t.spawn_launcher;
      return out;
    }),
  };
}

// Toggle a launcher on a type: its model field and spawn_launcher follow (a launcher the type no longer runs keeps no
// model and cannot be its spawn launcher).
export function toggleLauncher(t: TypeDraft, key: string, on: boolean): TypeDraft {
  const launchers = on ? [...t.launchers.filter((k) => k !== key), key] : t.launchers.filter((k) => k !== key);
  const models = Object.fromEntries(launchers.map((l) => [l, t.models[l] ?? ""]));
  return { ...t, launchers, models, spawn_launcher: launchers.includes(t.spawn_launcher) ? t.spawn_launcher : "" };
}

// Renaming a launcher key renames it in every type that runs it (its model and spawn_launcher too).
export function renameLauncher(d: Draft, i: number, key: string): Draft {
  const old = d.launchers[i]!.key;
  const launchers = d.launchers.map((l, j) => (j === i ? { ...l, key } : l));
  const types = d.types.map((t) => {
    if (!t.launchers.includes(old)) return t;
    const ls = t.launchers.map((k) => (k === old ? key : k));
    const models = Object.fromEntries(ls.map((l) => [l, l === key ? (t.models[old] ?? "") : (t.models[l] ?? "")]));
    return { ...t, launchers: ls, models, spawn_launcher: t.spawn_launcher === old ? key : t.spawn_launcher };
  });
  return { launchers, types };
}

// Removing a launcher drops it from every type.
export function removeLauncher(d: Draft, i: number): Draft {
  const key = d.launchers[i]!.key;
  return {
    launchers: d.launchers.filter((_, j) => j !== i),
    types: d.types.map((t) => (t.launchers.includes(key) ? toggleLauncher(t, key, false) : t)),
  };
}

const sameInvocation = (a: Invocation, b: Invocation) =>
  a.kind === b.kind &&
  a.command === b.command &&
  a.via_shell === b.via_shell &&
  a.args.length === b.args.length &&
  a.args.every((x, i) => x === b.args[i]);

// the allowlist entry a launcher is, or -1 when it is none
export const invocationIndex = (commands: Invocation[], l: Invocation) =>
  commands.findIndex((c) => sameInvocation(c, l));

export const invocationLine = (c: Invocation) =>
  `${c.kind === "hermes" ? "hermes" : "Claude Code"} · ${[c.command, ...c.args].join(" ")}${c.via_shell ? " (via shell)" : ""}`;

export const withInvocation = (l: Launcher, c: Invocation): Launcher => ({
  ...l,
  kind: c.kind,
  command: c.command,
  args: [...c.args],
  via_shell: c.via_shell,
});

// a new launcher is the host's first invocation; its key and label are typed in
export const newLauncher = (commands: Invocation[]): Launcher =>
  withInvocation({ key: "", label: "", ...commands[0]!, args: [] }, commands[0]!);

export const newType = (launchers: Launcher[]): TypeDraft => ({
  key: "",
  label: "",
  launchers: launchers.length ? [launchers[0]!.key] : [],
  models: launchers.length ? { [launchers[0]!.key]: "" } : {},
  hasPrompt: false,
  prompt: "",
  agent_name: "claude-{session}",
  session_name: "{slug}_session",
  takes: [],
  max: 0,
  max_per_project: 0,
  spawns_for: [],
  launcher_follows: "",
  spawn_launcher: "",
});

export const sameDoc = (a: AgentDoc, b: AgentDoc) => JSON.stringify(a) === JSON.stringify(b);
