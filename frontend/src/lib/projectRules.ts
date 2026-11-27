// A project's Settings tab: EVERY file of the repo's own `.busyyaks/skills/` (GET /api/projects/<slug>/agent-rules) —
// agents/<type>.md (adds to, or with `mode: replace` replaces, the global rules of the type) and on-demand skills
// <name>/SKILL.md + their .md files (a global skill's name replaces that skill for this project) — as an editable
// draft and back, plus why Save is off and what a launch does with the files. The server (Busyyaks::AgentRuleFiles +
// the writer's launch check: Skills.project + select + check_selection!) is the validator — its refusal is shown
// verbatim; the checks here mirror its rules so Save is off, with the reason, before a round trip. Pure: tested by
// projectRules.test.ts.

import type { AgentTypeInfo, GlobalFile, Source } from "./agentRules";

export type AgentType = AgentTypeInfo;
// the global layers each file adds to or replaces (Settings → Agent rules' view), or null + global_error
export type GlobalLayers = {
  agent_types: AgentTypeInfo[];
  files: (Pick<GlobalFile, "path" | "source" | "kind" | "load" | "skill" | "description" | "bytes" | "html"> & {
    body?: string | null;
    replaced_by?: Source | null;
  })[];
};
export type FileKind = "agent" | "skill" | "skill_ref";
export type Mode = "add" | "replace";
// body = the file with LF line ends (a textarea's); eol = what the file has ("crlf": a save writes CRLF back); sha =
// the bytes the editor loaded (a save's base); mode = an agents file's frontmatter (null: unreadable)
export type RuleFile = {
  body: string;
  sha: string;
  eol: "lf" | "crlf";
  kind: FileKind;
  type?: string;
  skill?: string;
  mode: Mode | null;
};
// what a launch of one type stages (Skills.composition, bin/launcher's own select): each earlier layer's file with the
// source that replaced it (null = staged)
export type Composition = {
  start: { path: string; source: Source; kind: string; mode: Mode | null; replaced_by: Source | null }[];
  on_demand: { name: string; source: Source; dir: string; replaces: Source | null; replaced_by: Source | null }[];
};
// what a launch does with the repo's .busyyaks/skills (asked of bin/launcher: its trust decision, its checks)
// budget / replace_budget = per agent type, the bytes its agents file may hold so a launch of the type still starts,
// adding / replacing; layers = per type, the launch's composition. All null when the launcher gave no answer.
export type Launches = {
  state: "loaded" | "none" | "left" | "refused" | "unknown";
  reason: string | null;
  budget: Record<string, number> | null;
  replace_budget?: Record<string, number> | null;
  layers?: Record<string, Composition> | null;
  checkout: boolean | null;
};
export type ProjectRulesData = {
  project: string;
  dir: string; // .busyyaks/skills
  path: string; // the dir on the host
  types: AgentType[]; // the current agent settings' types, in their order
  roles: string[]; // the roles of the repo's .busyyaks/agents.yml — each one's brief is agents/<role>.md
  files: Record<string, RuleFile>; // path (relative to dir) → its file
  creatable: string[]; // agents/<type>.md no file holds yet
  errors: Record<string, string>; // path → why it cannot be edited here ("" = the whole dir)
  git: Record<string, GitState>; // path → what git holds of it (a file removed but in git: "deleted")
  git_error: string | null;
  max_bytes: number; // config/busyyaks.yml skills.max_bytes
  launches: Launches;
  global: GlobalLayers | null;
  global_error: string | null;
};
export type GitState = "committed" | "modified" | "added" | "ignored" | "untracked" | "deleted";
// path → text; null = remove the file on Save. A path that is not a loaded file is a new one.
export type Draft = Record<string, string | null>;
export type Change = { base: string | null; body: string | null }; // body null = remove the file

export const rulesPath = (slug: string): string =>
  `/api/projects/${slug.split("/").map(encodeURIComponent).join("/")}/agent-rules`;

export const fileName = (data: Pick<ProjectRulesData, "dir">, path: string): string => `${data.dir}/${path}`;
export const agentPath = (type: string): string => `agents/${type}.md`;

// what a path is (the server's AgentRuleFiles.kind!)
export function kindOf(path: string): { kind: FileKind; type?: string; skill?: string } {
  const [dir, name = ""] = path.split("/");
  if (dir === "agents") return { kind: "agent", type: name.replace(/\.md$/, "") };
  return { kind: name === "SKILL.md" ? "skill" : "skill_ref", skill: dir };
}

// every loaded file and every agents/<type>.md no file holds yet gets an editor
export function toDraft(data: ProjectRulesData): Draft {
  const out: Draft = {};
  for (const [p, f] of Object.entries(data.files)) out[p] = f.body;
  for (const p of data.creatable) out[p] = "";
  return out;
}

export const bytes = (text: string): number => new TextEncoder().encode(text).length;
const blank = (t: string | null | undefined) => !t || t.trim() === "";

export function changedPaths(draft: Draft, data: ProjectRulesData): string[] {
  return Object.keys(draft).filter((p) => {
    if (data.errors[p]) return false;
    const f = data.files[p];
    const t = draft[p];
    if (!f) return !blank(t); // a new file (or a creatable agents file): only once it has text
    if (t === null) return true; // removed
    return f.kind === "agent" && blank(t) ? true : t !== f.body;
  });
}

// what a Save sends: only the changed files, each against the sha the editor loaded (null = there was no file)
export function changes(draft: Draft, data: ProjectRulesData): Record<string, Change> {
  const out: Record<string, Change> = {};
  for (const p of changedPaths(draft, data)) {
    const t = draft[p];
    const f = data.files[p];
    out[p] = { base: f?.sha ?? null, body: t === null || (f?.kind === "agent" && blank(t)) ? null : (t ?? "") };
  }
  return out;
}

// Skills::SHELL_INLINE: Claude Code runs a skill's !`cmd` as a shell command — the first line holding one, or null
export function shellLine(text: string): number | null {
  const i = text.split("\n").findIndex((l) => l.includes("!`"));
  return i < 0 ? null : i + 1;
}

// A frontmatter at the very start (the server's /\A---\r?\n(.*?)^---\r?\n/m)
const FRONT = /^---\r?\n([\s\S]*?\n)?---\r?\n/;

// an agents file's mode: no frontmatter = add; `mode: add|replace` = that; anything else = null (refused)
export function modeOf(text: string): Mode | null {
  const m = FRONT.exec(text);
  if (!m) return "add";
  const lines = (m[1] ?? "").split("\n").filter((l) => l.trim() !== "");
  const one = lines.length === 1 ? /^mode:\s*(add|replace)\s*$/.exec(lines[0]!) : null;
  return one ? (one[1] as Mode) : null;
}
export const afterFront = (text: string): string => text.replace(FRONT, "");

// the text with its mode set: replace = the frontmatter `mode: replace` on top; add = no frontmatter (the default)
export function withMode(text: string, mode: Mode): string {
  const rest = modeOf(text) === null ? text : afterFront(text);
  return mode === "replace" ? `---\nmode: replace\n---\n${rest}` : rest;
}

// a SKILL.md's frontmatter: its name and description (both required, one line each), or why not
export function skillFront(text: string): { name: string; description: string } | string {
  const m = FRONT.exec(text);
  if (!m) return "SKILL.md needs its frontmatter (--- name, description ---)";
  const kv = Object.fromEntries(
    (m[1] ?? "")
      .split("\n")
      .filter((l) => l.trim() !== "")
      .map((l) => {
        const i = l.indexOf(":");
        return [l.slice(0, i).trim(), l.slice(i + 1).trim()];
      }),
  );
  if (!kv.name || !kv.description) return "SKILL.md's frontmatter needs name and description";
  return { name: kv.name, description: kv.description };
}

// The bytes an agents file may hold so its type's launch still starts: the launcher's budget for its mode, never more
// than skills.max_bytes. `launch` = the launch budget is the limit shown.
export function limit(data: ProjectRulesData, type: string, mode: Mode | null): { bytes: number; launch: boolean } {
  const room = (mode === "replace" ? data.launches.replace_budget : data.launches.budget)?.[type];
  return room !== undefined && room < data.max_bytes
    ? { bytes: room, launch: true }
    : { bytes: data.max_bytes, launch: false };
}

// one editor's refusal (null = fine): the server's rules for its kind
export function fieldRefusal(path: string, text: string | null, draft: Draft, data: ProjectRulesData): string | null {
  if (text === null) return null; // removed
  const k = kindOf(path);
  if (k.kind === "agent") {
    const mode = modeOf(text);
    if (mode === null) return "an agents file's frontmatter is exactly `mode: add` or `mode: replace` (or none)";
    if (mode === "add" && blank(afterFront(text))) return null; // = no file
    if (bytes(text) > data.max_bytes) return `${bytes(text)} bytes · over ${data.max_bytes}`;
    const max = limit(data, k.type ?? "", mode);
    const n = bytes(afterFront(text));
    if (n > max.bytes)
      return max.launch
        ? `${n} bytes · over ${max.bytes}: a ${k.type} launch would be refused`
        : `${n} bytes · over ${max.bytes}`;
  } else {
    if (blank(text)) return "a skill file holds text: Remove it instead";
    if (k.kind === "skill") {
      const front = skillFront(text);
      if (typeof front === "string") return front;
      if (front.name !== k.skill) return `name ${front.name} must be its dir's ${k.skill}`;
    }
    const dir = `${k.skill}/`;
    const total = Object.entries(draft)
      .filter(([p, t]) => p.startsWith(dir) && t !== null)
      .reduce((n, [, t]) => n + bytes(t ?? ""), 0);
    if (total > data.max_bytes) return `the ${k.skill} skill is ${total} bytes · over ${data.max_bytes}`;
  }
  const line = shellLine(text);
  if (line !== null) return `line ${line}: !\`…\` runs as a shell command`;
  return null;
}

// a skill file of a skill whose SKILL.md is removed (or never made) while its other files stay: refused by a launch
function orphanRefusal(draft: Draft): string | null {
  const dirs = new Set(
    Object.entries(draft)
      .filter(([p, t]) => kindOf(p).kind === "skill_ref" && t !== null && !blank(t))
      .map(([p]) => p.split("/")[0]!),
  );
  for (const d of dirs) if (blank(draft[`${d}/SKILL.md`])) return `${d}: a skill needs its SKILL.md`;
  return null;
}

// why Save is off, or null
export function saveRefusal(draft: Draft, data: ProjectRulesData): string | null {
  const changed = changedPaths(draft, data);
  for (const p of changed) {
    const why = fieldRefusal(p, draft[p] ?? null, draft, data);
    if (why) return `${p}: ${why}`;
  }
  const orphan = orphanRefusal(draft);
  if (orphan) return orphan;
  if (changed.length === 0) return "nothing changed";
  return null;
}

// --- new files ---------------------------------------------------------------------------------------------------

const RESERVED = ["core", "agents", "session"];
export const SKILL_NAME = /^[a-z0-9-]{1,64}$/;
export const REF_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.md$/;

// the global on-demand skills (name → its SKILL.md): what a project skill of that name replaces
export function globalSkills(data: ProjectRulesData): { name: string; source: Source; body: string | null }[] {
  return (data.global?.files ?? [])
    .filter((f) => f.kind === "skill" && !f.replaced_by && f.skill)
    .map((f) => ({ name: f.skill!, source: f.source, body: f.body ?? null }));
}

// the skills of this project (by dir), in the draft
export const projectSkills = (draft: Draft): string[] =>
  [
    ...new Set(
      Object.keys(draft)
        .filter((p) => kindOf(p).kind !== "agent")
        .map((p) => p.split("/")[0]!),
    ),
  ].sort();

// why a new skill name is refused (null = fine)
export function newSkillRefusal(name: string, draft: Draft): string | null {
  if (!SKILL_NAME.test(name)) return "a skill name is a-z, 0-9 and -, at most 64";
  if (RESERVED.includes(name)) return `${name} is busyyaks's own (core is edited on Settings → Agent rules)`;
  if (projectSkills(draft).includes(name)) return `${name} is a skill of this project already`;
  return null;
}

// a new skill's SKILL.md: a copy of the global skill of that name (to override it), else a frontmatter to fill
export function newSkillText(name: string, data: ProjectRulesData): string {
  const g = globalSkills(data).find((s) => s.name === name);
  if (g?.body) return g.body;
  return `---\nname: ${name}\ndescription: what this skill is for, and when a session loads it\n---\n# ${name}\n\n`;
}

export function newRefRefusal(skill: string, file: string, draft: Draft): string | null {
  if (!REF_NAME.test(file) || file === "SKILL.md") return "a reference file is <name>.md (letters, digits, . _ -)";
  if (`${skill}/${file}` in draft) return `${skill}/${file} exists`;
  return null;
}

// --- what the page says ------------------------------------------------------------------------------------------

// The line beside Save: the server's answer to the last save, else why Save is off.
//   409 = a file changed on disk since the editor read it: the newest is offered (`reload`), the edits kept until taken
//   422 = refused: the server's reason verbatim (it names the file and the rule)
//   503 / 504 = the writer service is down / did not answer
export type SaveError = { status: number; text: string }; // status 0 = no answer (network)
export type SaveStatus = { tone: "bad" | "ok" | "muted"; text: string; reload: boolean };
export function saveStatus(error: SaveError | null, saved: string[] | null, refusal: string | null): SaveStatus {
  if (error?.status === 409) return { tone: "bad", text: `conflict · ${error.text}`, reload: true };
  if (error?.status === 422) return { tone: "bad", text: `refused · ${error.text}`, reload: false };
  if (error) return { tone: "bad", text: `${error.status || "no answer"} · ${error.text}`, reload: false };
  if (saved) return { tone: "ok", text: `written · ${saved.join(", ")} · read at the next launch`, reload: false };
  return { tone: "muted", text: refusal ?? "", reload: false };
}

// What a launch does with these files, said on the page: they reach a session only inside the busyyaks skill of a
// launch — and not at all when the repo's layer is left out (skills.project deny, a repo busyyaks does not trust) or
// invalid (the launch is refused). `unknown` = the launcher did not answer: said, never guessed.
export type LaunchLine = { tone: "ok" | "warn" | "bad" | "muted"; text: string };
export function launchLine(launches: Launches): LaunchLine {
  const why = launches.reason ? ` · ${launches.reason}` : "";
  switch (launches.state) {
    case "loaded":
      return { tone: "ok", text: "read at launch · busyyaks-launched sessions only" };
    case "none":
      return { tone: "muted", text: "no files yet · busyyaks-launched sessions only" };
    case "left":
      return { tone: "warn", text: `left out of launches${why}` };
    case "refused":
      return { tone: "bad", text: `launches refused${why}` };
    case "unknown":
      return { tone: "bad", text: `launch state unknown${why}` };
  }
}

// One type's launch, as the launcher composes it: every global file it starts with, each added or replaced (and by
// which layer), then this project's file — or why it is not known (no launcher answer).
export type TypeLayer = { path: string; source: Source; state: "added" | "replaced"; by: Source | null };
export function typeLayers(data: ProjectRulesData, type: string): TypeLayer[] | string {
  const comp = data.launches.layers?.[type];
  if (!comp) return `launch view unknown · ${data.launches.reason ?? "no answer from the launcher"}`;
  return comp.start.map((f) => ({
    path: f.path,
    source: f.source,
    state: f.replaced_by ? "replaced" : "added",
    by: f.replaced_by,
  }));
}

// The on-demand skills a launch of the type stages, each replaced or not (the launcher's composition)
export function typeSkills(data: ProjectRulesData, type: string): Composition["on_demand"] {
  return data.launches.layers?.[type]?.on_demand ?? [];
}

// the global file's render and size, by path (the Agent rules view)
export const globalFile = (data: ProjectRulesData, path: string) => data.global?.files.find((f) => f.path === path);

// What the page edits: the files it was loaded from + the draft. A read of the server (the first, a reload) becomes
// the form only while nothing is edited — never over the operator's typing (a 409 then offers the newest).
export type Form = { loaded: ProjectRulesData; draft: Draft };
export const formOf = (data: ProjectRulesData): Form => ({ loaded: data, draft: toDraft(data) });
export const nextForm = (form: Form | null, data: ProjectRulesData): Form =>
  !form || changedPaths(form.draft, form.loaded).length === 0 ? formOf(data) : form;

// the files on disk are not the ones the form was loaded from (someone edited the repo, another tab saved)
export function stale(form: Form, data: ProjectRulesData): string[] {
  const paths = new Set([...Object.keys(form.loaded.files), ...Object.keys(data.files)]);
  return [...paths].filter((p) => (form.loaded.files[p]?.sha ?? null) !== (data.files[p]?.sha ?? null)).sort();
}

// The git tag on an editor: whether the file is tracked, and that an edit of a tracked file is an uncommitted change in
// the repo (busyyaks writes the file, it never commits). `changed` = the editor differs from the file on disk.
export type GitTag = { tone: "muted" | "warn"; text: string };
export function gitTag(state: GitState | undefined, changed: boolean): GitTag | null {
  switch (state) {
    case "committed":
      return changed
        ? { tone: "warn", text: "tracked by git · Save leaves an uncommitted change" }
        : { tone: "muted", text: "tracked by git · committed" };
    case "modified":
      return { tone: "warn", text: "tracked by git · uncommitted change" };
    case "added":
      return { tone: "warn", text: "staged · not committed" };
    case "untracked":
      return { tone: "warn", text: "not in git yet · commit it with the repo" };
    case "ignored":
      return { tone: "warn", text: "ignored by git · never committed with the repo" };
    case "deleted":
      return { tone: "warn", text: "tracked by git · removed, uncommitted" };
    case undefined:
      return null;
  }
}

// files git still holds that are gone from the work tree (a removal not committed yet)
export const deletedInGit = (data: ProjectRulesData): string[] =>
  Object.entries(data.git)
    .filter(([p, s]) => s === "deleted" && !data.files[p])
    .map(([p]) => p)
    .sort();

// Leaving the Settings tab with unsaved editors would drop them without a word: refused, said (null = go).
export function leaveRefusal(from: string, to: string, unsaved: number): string | null {
  if (from !== "settings" || to === "settings" || unsaved === 0) return null;
  return `${unsaved} unsaved rule ${unsaved === 1 ? "file" : "files"} · Save or Discard first`;
}

// busyyaks's own checkout as a project: `yaks update` refuses a checkout whose tracked files are uncommitted — the
// files here that are (null = nothing to say)
export function checkoutLine(data: ProjectRulesData): string | null {
  if (!data.launches.checkout) return null;
  const dirty = Object.entries(data.git)
    .filter(([, s]) => ["modified", "added", "deleted"].includes(s))
    .map(([p]) => p)
    .sort();
  return dirty.length
    ? `busyyaks's own checkout · yaks update is refused until ${dirty.join(", ")} is committed`
    : "busyyaks's own checkout · yaks update refuses it while a tracked file here is uncommitted";
}
