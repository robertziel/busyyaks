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
  // lead-first boards: the lead type a session of this type runs under (only while it runs, on its launcher)
  under?: string | null;
  // a plain session that runs with no lead (only a type with no prompt that takes nothing; card 463)
  standalone?: boolean;
  // false = the Launch bar never offers it: only its lead's kanban_spawn starts one (absent = offered)
  launchable?: boolean;
  // the Launch bar button's text ("Launch team lead"); absent / null = the label
  launch_label?: string | null;
  // true = a board runs it only when its repo's .busyyaks/agents.yml `use`s it (needs under + launchable false)
  opt_in?: boolean;
  // the faces' colour, a name of AgentSettingsData.colors (absent = the theme's, else a hue from the key)
  color?: string;
};
// config/agent_presets.yml — an agent type without launchers (the lead's are filled in) + its description
export type Preset = Omit<AgentType, "launchers"> & { description: string };
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
  presets: Preset[]; // the "Add from preset" list
  colors: Record<string, string>; // colour name → CSS value (skin tokens): what a type's `color` may be
  face_theme: Record<string, string>; // type key → CSS value the host config's theme gives a type with no colour
};

// the engine's FIXED column types (agents_kanban ColumnTypes): what `takes` names
export const COLUMN_TYPES = ["parked", "queued", "working", "review", "gate", "done", "cancelled"] as const;

// In the form a type's model is always one field per launcher it runs ("" = Claude Code's own choice).
export type TypeDraft = Omit<
  AgentType,
  "model" | "prompt" | "under" | "standalone" | "launchable" | "launch_label" | "opt_in" | "color"
> & {
  color: string; // "" = none of its own
  optIn: boolean; // kept through the form: a save never puts an opt-in type on every board
  standalone: boolean; // kept through the form: a save never drops it (plain would then be a type under no lead)
  launchable: boolean; // kept through the form: a save never puts a spawn-only type back on the Launch bar
  launchLabel: string; // "" = the button says the label
  models: Record<string, string>;
  hasPrompt: boolean;
  prompt: string;
  under: string; // "" = runs on its own
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
      under: t.under ?? "",
      standalone: t.standalone === true,
      launchable: t.launchable !== false,
      launchLabel: t.launch_label ?? "",
      optIn: t.opt_in === true,
      color: t.color ?? "",
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
      if (t.under) out.under = t.under;
      if (t.standalone) out.standalone = true;
      if (!t.launchable) out.launchable = false;
      if (t.launchLabel.trim()) out.launch_label = t.launchLabel.trim();
      if (t.optIn) out.opt_in = true;
      if (t.color) out.color = t.color;
      return out;
    }),
  };
}

// Toggle a launcher on a type: its model field follows (a launcher the type no longer runs keeps no model).
export function toggleLauncher(t: TypeDraft, key: string, on: boolean): TypeDraft {
  const launchers = on ? [...t.launchers.filter((k) => k !== key), key] : t.launchers.filter((k) => k !== key);
  const models = Object.fromEntries(launchers.map((l) => [l, t.models[l] ?? ""]));
  return { ...t, launchers, models };
}

// Renaming a launcher key renames it in every type that runs it (its model too).
export function renameLauncher(d: Draft, i: number, key: string): Draft {
  const old = d.launchers[i]!.key;
  const launchers = d.launchers.map((l, j) => (j === i ? { ...l, key } : l));
  const types = d.types.map((t) => {
    if (!t.launchers.includes(old)) return t;
    const ls = t.launchers.map((k) => (k === old ? key : k));
    const models = Object.fromEntries(ls.map((l) => [l, l === key ? (t.models[old] ?? "") : (t.models[l] ?? "")]));
    return { ...t, launchers: ls, models };
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
  session_name: "by_{slug}_session",
  takes: [],
  max: 0,
  max_per_project: 0,
  under: "",
  standalone: false,
  launchable: true,
  launchLabel: "",
  optIn: false,
  color: "",
});

// a preset as a draft type — it runs the launchers of the lead it is under (the engine's rule for a type
// under a lead); no such lead in the draft → no launcher: the save is refused naming it, never a launcher guessed
export function fromPreset(d: Draft, p: Preset): TypeDraft {
  const lead = d.types.find((t) => t.key === p.under);
  const launchers = lead ? [...lead.launchers] : [];
  const type: AgentType = {
    key: p.key,
    label: p.label,
    launchers,
    model: p.model,
    prompt: p.prompt,
    agent_name: p.agent_name,
    session_name: p.session_name,
    takes: [...p.takes],
    max: p.max,
    max_per_project: p.max_per_project,
    under: p.under ?? null,
    launchable: p.launchable,
    opt_in: p.opt_in,
  };
  return toDraft({ launchers: d.launchers, agent_types: [type] }).types[0]!;
}

// the presets not in the draft yet (by key)
export const presetsLeft = (d: Draft, presets: Preset[]) =>
  presets.filter((p) => !d.types.some((t) => t.key === p.key));

export const sameDoc = (a: AgentDoc, b: AgentDoc) => JSON.stringify(a) === JSON.stringify(b);

// "runs under" offers only the types that can lead: one that runs under no lead itself and is not a standalone plain
// session (the engine refuses a type under a worker, a sub team or a plain session)
export function leadChoices(types: TypeDraft[], self: TypeDraft): string[] {
  return types.filter((t) => t !== self && t.key !== self.key && !t.under && !t.standalone).map((t) => t.key);
}

// the CSS colour a type's faces wear — its own colour, else the theme's for its key; null = the engine's hue
// hashed from the key (the face draws it itself)
export function faceColor(t: Pick<TypeDraft, "key" | "color">, data: Pick<AgentSettingsData, "colors" | "face_theme">) {
  if (t.color && data.colors[t.color]) return data.colors[t.color]!;
  return data.face_theme[t.key.trim()] ?? null;
}

// the first palette colour no type of the draft wears yet (its own or the theme's); "" when every one is taken
export function freeColor(d: Draft, data: Pick<AgentSettingsData, "colors" | "face_theme">): string {
  const worn = new Set(d.types.map((t) => faceColor(t, data)).filter((c): c is string => c !== null));
  return Object.keys(data.colors).find((name) => !worn.has(data.colors[name]!)) ?? "";
}

// per type (by index): the other types that wear the same colour, or undefined
export function colorClashes(d: Draft, data: Pick<AgentSettingsData, "colors" | "face_theme">) {
  const worn = d.types.map((t) => faceColor(t, data));
  return d.types.map((_, i) => {
    const c = worn[i];
    if (!c) return undefined;
    const others = d.types.filter((_o, j) => j !== i && worn[j] === c).map((o) => o.key || "new type");
    return others.length ? others : undefined;
  });
}

// what a type IS, as short tags for its row: its place (lead · under <lead> · standalone · no lead) and how it starts
export function typeTags(t: TypeDraft): string[] {
  const tags = [t.standalone ? "standalone" : t.under ? `under ${t.under}` : "lead"];
  tags.push(t.launchable ? "Launch bar" : "spawned by its lead");
  if (t.optIn) tags.push("opt-in per board");
  if (t.takes.length) tags.push(`takes ${t.takes.join(" · ")}`);
  return tags;
}
