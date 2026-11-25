// Settings → Agent rules (GET /api/settings/agent-rules): busyyaks's OWN skills layers — every global markdown a
// session busyyaks launches gets — one card per file, grouped by who gets it, and the names / purposes of the agent
// types both this page and a project's Settings tab show. The server (bin/launcher's skills_layers = the launch's own
// selection; the writer's SkillFiles = the launch's own checks) is the source and the validator: the checks here only
// turn Save off with a reason before a round trip. Pure: tested by agentRules.test.ts.
import { getJSON, set } from "./store";

// an agent type as the agent settings define it; start / on_demand / start_bytes / budget come with the layers view
export type AgentTypeInfo = {
  key: string;
  label: string;
  under: string | null;
  takes: string[];
  standalone: boolean;
  start?: string[]; // the files its entry skill holds, in launch order
  on_demand?: string[]; // the on-demand skills it may load
  start_bytes?: number; // what busyyaks's layers put into its entry skill now
  budget?: number; // what its project's agents/<type>.md may still hold
};
export type Source = "busyyaks" | "deployment" | "project";
export type Kind = "core" | "core_ref" | "agent" | "skill" | "skill_ref";
export type GitState = "committed" | "modified" | "added" | "ignored" | "untracked" | "deleted";
export type GlobalFile = {
  path: string; // relative to the busyyaks checkout
  source: Source;
  kind: Kind;
  load: "start" | "on_demand";
  skill: string | null;
  description: string | null;
  dispatch?: string | null; // an on-demand skill's SKILL.md frontmatter `dispatch`: who dispatches it, when (one line)
  replaced_by?: Source | null; // a later layer's file stands in for it (the override rule): it is in no launch
  type: string | null; // an agents/<type>.md's type
  exists: boolean; // false = no file yet (an empty card: Save makes it)
  bytes: number;
  sha: string | null;
  eol: "lf" | "crlf";
  body: string | null; // LF line ends; null = not UTF-8 (error says so)
  html: string | null; // rendered by the server (Busyyaks::Markdown), frontmatter left out
  git?: GitState;
  error: string | null;
};
export type Limits = { max_bytes: number; max_start_bytes: number; project: string; local_dir: string | null };
export type AgentRulesData = {
  checkout: { host: string; mount: string | null; error: string | null };
  limits: Limits;
  agent_types: AgentTypeInfo[];
  files: GlobalFile[];
  git_error: string | null;
};

export const RULES_PATH = "/api/settings/agent-rules";
export const PAGE = "/settings/agent-rules";

// --- naming -------------------------------------------------------------------------------------------------------

// the types that run under `t` (it is their lead)
export const underIt = (t: AgentTypeInfo, all: AgentTypeInfo[]): AgentTypeInfo[] =>
  all.filter((o) => o.under === t.key);
export const isLead = (t: AgentTypeInfo, all: AgentTypeInfo[]): boolean =>
  underIt(t, all).length > 0 || t.takes.length > 0;

// What a type IS, from its config (never from its key): the lead (others run under it, or it adopts cards), one
// under a lead, or a plain standalone session. The title is the type's label — the agent settings' name for it.
export type Role = "lead" | "under" | "standalone" | "other";
export function role(t: AgentTypeInfo, all: AgentTypeInfo[]): Role {
  if (t.standalone) return "standalone";
  if (t.under) return "under";
  return isLead(t, all) ? "lead" : "other";
}

export const typeTitle = (t: AgentTypeInfo): string => t.label;

export function typeByKey(all: AgentTypeInfo[], key: string | null | undefined): AgentTypeInfo | undefined {
  return all.find((t) => t.key === key);
}

// one line: what a session of the type does on the board, derived from under / takes / standalone
export function purpose(t: AgentTypeInfo, all: AgentTypeInfo[]): string {
  switch (role(t, all)) {
    case "lead": {
      const team = underIt(t, all).map((o) => o.label);
      const takes = t.takes.length ? `adopts every ownerless card in ${t.takes.join(" · ")} columns` : "adopts no card";
      return `owns the board · ${takes}${team.length ? ` · starts ${team.join(", ")}` : ""}`;
    }
    case "under": {
      const lead = typeByKey(all, t.under);
      return `runs only while the ${lead?.label ?? t.under} runs, on its launcher · ${
        t.takes.length ? `adopts ${t.takes.join(" · ")}` : "adopts no card on its own"
      }`;
    }
    case "standalone":
      return "a plain session · no lead needed, adopts nothing, no board role";
    case "other":
      return t.takes.length ? `adopts ${t.takes.join(" · ")}` : "adopts no card";
  }
}

export const SOURCE_LABEL: Record<Source, string> = {
  busyyaks: "busyyaks",
  deployment: "this deployment",
  project: "this project",
};

// what a file is, in words
export function what(f: GlobalFile, all: AgentTypeInfo[]): string {
  switch (f.kind) {
    case "core":
      return "core skill · the board workflow";
    case "core_ref":
      return "core skill · reference file";
    case "agent": {
      const t = typeByKey(all, f.type);
      return `${t ? typeTitle(t) : f.type} rules`;
    }
    case "skill":
      return `on-demand skill · ${f.skill}`;
    case "skill_ref":
      return `on-demand skill ${f.skill} · reference file`;
  }
}

// who gets it: every session · the types whose entry skill holds it · on demand (types that may load it)
export function whoGets(f: GlobalFile, all: AgentTypeInfo[]): string {
  if (f.replaced_by) return `replaced by ${SOURCE_LABEL[f.replaced_by]}'s file of the same name · in no launch`;
  if (f.dispatch) return `dispatched by ${f.dispatch}`;
  if (f.load === "on_demand") {
    const may = all.filter((t) => t.on_demand?.includes(f.skill ?? ""));
    return may.length === all.length ? "on demand · any session loads it when the work needs it" : "on demand";
  }
  if (!f.exists) {
    const t = typeByKey(all, f.type);
    return `no file yet · Save makes it for every ${t ? typeTitle(t) : f.type} session`;
  }
  const at = all.filter((t) => t.start?.includes(f.path));
  if (at.length === all.length && all.length > 1) return "every busyyaks session, at start";
  return `every ${at.map(typeTitle).join(", ")} session, at start`;
}

// where a file is edited, said on its card: here (the writer writes the checkout) and in git (it is tracked there)
export function editedWhere(f: GlobalFile): string {
  const repo = f.source === "deployment" ? "this deployment's layer of the busyyaks checkout" : "the busyyaks repo";
  return `committed in ${repo}: ${f.path} — read at every launch`;
}

// --- groups: one card per file, grouped by who gets it ------------------------------------------------------------

export type Group = { key: string; title: string; note: string; files: GlobalFile[] };
export function groups(data: AgentRulesData): Group[] {
  const own = data.files.filter((f) => f.source === "busyyaks");
  const order = (f: GlobalFile) => data.agent_types.findIndex((t) => t.key === f.type);
  const agentFiles = (fs: GlobalFile[]) => fs.filter((f) => f.kind === "agent").sort((a, b) => order(a) - order(b));
  const out: Group[] = [
    {
      key: "every",
      title: "Every session",
      note: "the core skill: the first part of every entry skill busyyaks stages",
      files: own.filter((f) => f.kind === "core" || f.kind === "core_ref"),
    },
    {
      key: "types",
      title: "Per agent type",
      note: "agents/<type>.md: after the core, in each session of that type",
      files: agentFiles(own),
    },
    {
      key: "on_demand",
      title: "On demand",
      note: "listed in every entry skill; a session loads one when its work needs it",
      files: own.filter((f) => f.kind === "skill" || f.kind === "skill_ref"),
    },
  ];
  const dep = data.files.filter((f) => f.source === "deployment");
  if (data.limits.local_dir)
    out.push({
      key: "deployment",
      title: "This deployment",
      note: `config/busyyaks.yml skills.local_dir = ${data.limits.local_dir}: after busyyaks's own, in every launch`,
      files: [...agentFiles(dep), ...dep.filter((f) => f.kind !== "agent")],
    });
  return out.filter((g) => g.files.length > 0);
}

// a card's DOM id (the project tab links to it)
export const anchor = (path: string): string => `rule-${path.replace(/[^A-Za-z0-9]+/g, "-")}`;

// --- the launch budget: ONE number per card, its breakdown in the tooltip -----------------------------------------

export const bytes = (text: string): number => new TextEncoder().encode(text).length;
// a SKILL.md's frontmatter does not count toward the entry skill (Skills reads core's body without it)
// FRONT = the server's /\A---\r?\n(.*?)^---\r?\n/m: from the very start of the text only (no `m` flag here: ^ = the
// start), the closing --- at the start of a line
export const FRONT = /^---\r?\n(?:[\s\S]*?\n)?---\r?\n/;
export const stripFront = (text: string): string => text.replace(FRONT, "");
const counted = (f: GlobalFile, text: string) => (f.kind === "core" ? bytes(stripFront(text)) : bytes(text));

export type Budget = { max: number; tip: string };
// What the file may hold so every launch still starts: an entry-skill file (core, agents/<type>.md) is bounded by
// max_start_bytes less what else that launch's entry skill holds (the tightest type), and by max_bytes; an on-demand
// skill's file by max_bytes less its skill's other files (Skills: one skill dir's size).
export function budget(f: GlobalFile, data: AgentRulesData): Budget {
  const { max_bytes: maxB, max_start_bytes: maxS } = data.limits;
  const fmt = (n: number) => n.toLocaleString("en-US");
  if (f.load === "on_demand") {
    const others = data.files
      .filter((o) => o.skill === f.skill && o.source === f.source && o.path !== f.path)
      .reduce((n, o) => n + o.bytes, 0);
    const room = Math.max(0, maxB - others);
    return {
      max: room,
      tip: `skills.max_bytes ${fmt(maxB)} for the ${f.skill} skill − its other files ${fmt(others)}`,
    };
  }
  if (f.kind === "core_ref") return { max: maxB, tip: `skills.max_bytes ${fmt(maxB)} (not in the entry skill)` };
  const mine = f.body !== null ? counted(f, f.body) : 0;
  const types = data.agent_types.filter((t) => (f.exists ? t.start?.includes(f.path) : t.key === f.type));
  let tightest: { room: number; t: AgentTypeInfo | null } = { room: maxB, t: null };
  for (const t of types) {
    const room = maxS - ((t.start_bytes ?? 0) - mine);
    if (room < tightest.room) tightest = { room, t };
  }
  const t = tightest.t;
  const tip = t
    ? `skills.max_start_bytes ${fmt(maxS)} − the rest of the ${typeTitle(t)} entry skill ${fmt((t.start_bytes ?? 0) - mine)}`
    : `skills.max_bytes ${fmt(maxB)}`;
  return { max: Math.max(0, tightest.room), tip };
}

// --- the form -----------------------------------------------------------------------------------------------------

export type Draft = Record<string, string>; // path → text
export type Change = { base: string | null; body: string | null }; // body null = remove (an agents file only)

export const toDraft = (data: AgentRulesData): Draft =>
  Object.fromEntries(data.files.filter((f) => f.body !== null).map((f) => [f.path, f.body ?? ""]));

const same = (text: string, f: GlobalFile) => (f.exists ? text === f.body : text.trim() === "");
export const changedPaths = (draft: Draft, data: AgentRulesData): string[] =>
  data.files.filter((f) => f.body !== null && !same(draft[f.path] ?? "", f)).map((f) => f.path);

export function changes(draft: Draft, data: AgentRulesData): Record<string, Change> {
  const out: Record<string, Change> = {};
  for (const p of changedPaths(draft, data)) {
    const f = data.files.find((x) => x.path === p)!;
    const text = draft[p] ?? "";
    out[p] = { base: f.sha, body: text.trim() === "" ? null : text };
  }
  return out;
}

// Skills::SHELL_INLINE: the first line holding !`, or null
export function shellLine(text: string): number | null {
  const i = text.split("\n").findIndex((l) => l.includes("!`"));
  return i < 0 ? null : i + 1;
}

// one card's refusal (null = fine)
export function fieldRefusal(f: GlobalFile, text: string, data: AgentRulesData): string | null {
  if (text.trim() === "") return f.kind === "agent" ? null : "a skill file holds text: it cannot be blank";
  if ((f.kind === "core" || f.kind === "skill") && !FRONT.test(text))
    return "SKILL.md needs its frontmatter (--- name, description ---)";
  const max = budget(f, data).max;
  const n = f.kind === "core" ? bytes(stripFront(text)) : bytes(text);
  if (n > max)
    return `${n.toLocaleString("en-US")} bytes · over ${max.toLocaleString("en-US")}: a launch would be refused`;
  const line = shellLine(text);
  if (line !== null) return `line ${line}: !\`…\` runs as a shell command`;
  return null;
}

export function saveRefusal(draft: Draft, data: AgentRulesData): string | null {
  if (!data.checkout.mount)
    return `not writable here · ${data.checkout.error ?? "the writer cannot reach the checkout"}`;
  const changed = changedPaths(draft, data);
  for (const p of changed) {
    const f = data.files.find((x) => x.path === p)!;
    const why = fieldRefusal(f, draft[p] ?? "", data);
    if (why) return `${p}: ${why}`;
  }
  return changed.length ? null : "nothing changed";
}

// --- git: the files are tracked in the busyyaks repo; a save never commits -----------------------------------------

const UNCOMMITTED: GitState[] = ["modified", "added", "deleted", "untracked"];
// the line after a save (or whenever the checkout has them): which global files are not committed, and what that blocks
export function uncommitted(data: AgentRulesData): { paths: string[]; text: string } | null {
  const paths = data.files.filter((f) => f.git && UNCOMMITTED.includes(f.git)).map((f) => f.path);
  if (!paths.length) return null;
  return { paths, text: "uncommitted change in the busyyaks repo — `yaks update` refuses until it is committed" };
}

export function gitTag(state: GitState | undefined, changed: boolean): { tone: "muted" | "warn"; text: string } | null {
  switch (state) {
    case "committed":
      return changed
        ? { tone: "warn", text: "Save leaves an uncommitted change" }
        : { tone: "muted", text: "committed" };
    case "modified":
      return { tone: "warn", text: "uncommitted change" };
    case "added":
      return { tone: "warn", text: "staged · not committed" };
    case "untracked":
      return { tone: "warn", text: "not in git yet" };
    case "ignored":
      return { tone: "warn", text: "ignored by git" };
    case "deleted":
      return { tone: "warn", text: "removed · uncommitted" };
    case undefined:
      return null;
  }
}

// --- which cards are open: remembered per viewer ------------------------------------------------------------------

export const OPEN_KEY = "busyyaks.agent-rules-open";
export const openSet = (): string[] => getJSON<string[]>(OPEN_KEY, []);
export function toggleOpen(id: string, open: string[]): string[] {
  const next = open.includes(id) ? open.filter((x) => x !== id) : [...open, id];
  set(OPEN_KEY, JSON.stringify(next));
  return next;
}
