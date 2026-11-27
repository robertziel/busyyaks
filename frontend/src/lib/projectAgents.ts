// The project Settings tab's Agent types: the repo's .busyyaks/agents.yml — which opt-in agent types the
// board uses, its own roles (a type + a brief) and which type or role works each column. The server (the writer, then
// bin/launcher at every launch) is the only validator: this shapes the form and words what the launcher said. Pure:
// tested by projectAgents.test.ts.

export type Column = { key: string; label: string; type: string };
export type AgentsView = {
  use: string[];
  roles: Record<string, { label: string; like: string }>;
  columns: Record<string, string>;
};
export type ProjectAgentsData = {
  project: string;
  file: string; // .busyyaks/agents.yml
  path: string; // on the host
  text: string | null; // null = no file
  sha: string | null;
  error: string | null; // the file cannot be read here
  columns: Column[]; // the board's
  types: { key: string; label: string; opt_in: boolean }[]; // the types a lead starts
  presets: string[];
  // bin/launcher's answer: loaded · none · left (+ why: the file is NOT read) · refused (+ why) · unknown (+ why)
  launches: { state: string; reason: string | null; agents: AgentsView | null };
  briefs: Record<string, true>; // the agents/<name>.md files the repo's layer holds
  roles: string[]; // the role names of the file on disk (a role dropped from it takes its brief with it: drops)
};
// a brief for a role the file adds: written with it (a brief on disk is edited on its own card below)
export type NewBrief = { role: string; body: string };

export const agentsPath = (slug: string): string =>
  `/api/projects/${slug.split("/").map(encodeURIComponent).join("/")}/agents`;

const ROLE = /^[a-z][a-z0-9_-]{0,31}$/;

// what the launcher does with the file, one line + a tone
export function stateLine(l: ProjectAgentsData["launches"]): { text: string; tone: "ok" | "warn" | "bad" | "muted" } {
  switch (l.state) {
    case "loaded": {
      const a = l.agents!;
      const n = Object.keys(a.columns).length;
      const parts = [
        `use ${a.use.length ? a.use.join(", ") : "none"}`,
        `${Object.keys(a.roles).length} role${Object.keys(a.roles).length === 1 ? "" : "s"}`,
        `${n} column${n === 1 ? "" : "s"} mapped`,
      ];
      return { text: `loaded · ${parts.join(" · ")}`, tone: "ok" };
    }
    case "none":
      return { text: "no file · every column: any type the board runs; no opt-in type", tone: "muted" };
    case "left":
      return { text: `not read at launch · ${l.reason ?? ""}`, tone: "warn" };
    case "refused":
      return { text: `every launch on this board is refused · ${l.reason ?? ""}`, tone: "bad" };
    default:
      return { text: `launcher did not answer · ${l.reason ?? ""}`, tone: "warn" };
  }
}

// per board column: the type or role the lead starts there (as loaded), "any" when none is named
export function columnRows(d: ProjectAgentsData): { key: string; label: string; type: string; takes: string }[] {
  const a = d.launches.agents;
  return d.columns.map((c) => ({ ...c, takes: a?.columns[c.key] ?? "any" }));
}

// a starting text for a board with no file: its real column keys and opt-in types, every line a comment
export function example(d: ProjectAgentsData): string {
  const opt = d.types.filter((t) => t.opt_in).map((t) => t.key);
  const work = d.columns.filter((c) => !["parked", "done", "cancelled"].includes(c.type));
  return [
    `# use: [${opt.join(", ")}]          # opt-in types this board runs`,
    "# roles:                            # this project's own types: a type + a brief (agents/<role>.md)",
    "#   changelog: {label: Changelog writer, like: worker}",
    "# columns:                          # which type or role the lead starts for a card in that column",
    ...work.map((c) => `#   ${c.key}: worker`),
  ].join("\n");
}

// why Save is off (null = it may be pressed)
export function saveRefusal(
  text: string,
  loaded: string | null,
  briefs: NewBrief[],
  d: ProjectAgentsData,
  drops: string[] = [],
): string | null {
  if (d.error) return d.error;
  const same = (text.trim() === "" ? null : text) === loaded;
  if (same && briefs.length === 0 && drops.length === 0) return "nothing changed";
  const both = drops.find((r) => briefs.some((b) => b.role.trim() === r));
  if (both) return `${both}: a new brief and its removal in one save`;
  const names = briefs.map((b) => b.role.trim());
  const bad = names.find((n) => !ROLE.test(n));
  if (bad !== undefined) return `role name "${bad}" must match ${ROLE.source}`;
  const twice = names.find((n, i) => names.indexOf(n) !== i);
  if (twice) return `brief for ${twice} given twice`;
  const held = names.find((n) => d.briefs[n]);
  if (held) return `${held}: its brief exists already — edit it on its card below`;
  const empty = briefs.find((b) => b.body.trim() === "");
  if (empty) return `the brief of ${empty.role} is empty`;
  if (text.trim() === "" && briefs.length) return "removing the file takes no briefs";
  return null;
}

// the POST body: the whole file (empty = remove it), the sha it was loaded from, the new roles' briefs, and null for
// each role the save drops with its brief (a role and its brief go together)
export const saveBody = (text: string, d: ProjectAgentsData, briefs: NewBrief[], drops: string[] = []) => ({
  base: d.sha,
  text: text.trim() === "" ? null : text,
  briefs: {
    ...Object.fromEntries(briefs.map((b) => [b.role.trim(), b.body])),
    ...Object.fromEntries(drops.map((r) => [r, null])),
  },
});

// ---- the form: the file as checkboxes, rows and a select per column. It is
// built from what the launcher LOADED (the one parser is the server's); the form writes the whole file back.

// brief: only for a role with none on disk · disk: its brief is on disk (its name is then fixed: a rename would drop the
// brief file and ask for a new one)
export type FormRole = { name: string; label: string; like: string; brief: string; disk: boolean };
export type AgentsForm = { use: string[]; roles: FormRole[]; columns: Record<string, string> };

const NO_WORK = ["parked", "done", "cancelled"];
export const worksCards = (c: Column) => !NO_WORK.includes(c.type);

// the form of the file as loaded, an empty one for a board with no file, or null + why (the file is then edited as
// YAML: the launcher did not read it, so nothing here may shape it)
export function formOf(d: ProjectAgentsData): { form: AgentsForm | null; why: string | null } {
  if (d.error) return { form: null, why: d.error };
  const l = d.launches;
  if (l.state === "none") return { form: { use: [], roles: [], columns: {} }, why: null };
  if (l.state === "loaded" && l.agents) {
    const a = l.agents;
    return {
      form: {
        use: [...a.use],
        roles: Object.entries(a.roles).map(([name, r]) => ({
          name,
          label: r.label,
          like: r.like,
          brief: "",
          disk: !!d.briefs[name],
        })),
        columns: { ...a.columns },
      },
      why: null,
    };
  }
  return { form: null, why: `the form needs the file as the launcher read it — ${stateLine(l).text}` };
}

// a YAML scalar that reads back as exactly this string (JSON strings are YAML; no `on` / `no` turning into booleans)
const q = (s: string) => JSON.stringify(s);

// the form as the file's text; nothing named → "" (Save removes the file)
export function toYaml(f: AgentsForm): string {
  const out: string[] = [];
  if (f.use.length) out.push(`use: [${f.use.map(q).join(", ")}]`);
  if (f.roles.length) {
    out.push("roles:");
    f.roles.forEach((r) => out.push(`  ${q(r.name.trim())}: {label: ${q(r.label.trim())}, like: ${q(r.like)}}`));
  }
  const cols = Object.entries(f.columns).filter(([, v]) => v);
  if (cols.length) {
    out.push("columns:");
    cols.forEach(([k, v]) => out.push(`  ${q(k)}: ${q(v)}`));
  }
  return out.length ? `${out.join("\n")}\n` : "";
}

// the briefs a form save writes: one per role with no brief on disk yet
export const formBriefs = (f: AgentsForm, d: ProjectAgentsData): NewBrief[] =>
  f.roles.filter((r) => !d.briefs[r.name.trim()]).map((r) => ({ role: r.name.trim(), body: r.brief }));

// the roles of the file on disk the form no longer has, whose brief goes with them (a role and its brief go together)
export const formDrops = (f: AgentsForm, d: ProjectAgentsData): string[] =>
  d.roles.filter((r) => d.briefs[r] && !f.roles.some((x) => x.name.trim() === r));

// the types a column or a role may name: every type the lead starts, an opt-in one only while the board uses it
export const usable = (d: ProjectAgentsData, f: AgentsForm) =>
  d.types.filter((t) => !t.opt_in || f.use.includes(t.key));

// what a name in a column is: {face type key, label, role?} — a role wears its type's face
export function who(d: ProjectAgentsData, f: AgentsForm, name: string) {
  const r = f.roles.find((x) => x.name.trim() === name);
  const typeKey = r ? r.like : name;
  const t = d.types.find((x) => x.key === typeKey);
  return { type: typeKey, label: r ? r.label || r.name : (t?.label ?? name), role: r ? r.name : null };
}

// Turning an opt-in type off takes it out of every column and role naming it (else the save is refused for it)
export function withoutUse(f: AgentsForm, key: string): AgentsForm {
  const roles = f.roles.filter((r) => r.like !== key);
  const gone = new Set([key, ...f.roles.filter((r) => r.like === key).map((r) => r.name.trim())]);
  return {
    use: f.use.filter((k) => k !== key),
    roles,
    columns: Object.fromEntries(Object.entries(f.columns).filter(([, v]) => !gone.has(v))),
  };
}

// Renaming a role renames it in the columns; removing one empties the columns that named it
export function renameRole(f: AgentsForm, i: number, name: string): AgentsForm {
  const old = f.roles[i]!.name.trim();
  return {
    ...f,
    roles: f.roles.map((r, j) => (j === i ? { ...r, name } : r)),
    columns: Object.fromEntries(Object.entries(f.columns).map(([k, v]) => [k, v === old ? name.trim() : v])),
  };
}
export function removeRole(f: AgentsForm, i: number): AgentsForm {
  const old = f.roles[i]!.name.trim();
  return {
    ...f,
    roles: f.roles.filter((_, j) => j !== i),
    columns: Object.fromEntries(Object.entries(f.columns).filter(([, v]) => v !== old)),
  };
}
