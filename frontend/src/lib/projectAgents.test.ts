// The project Settings tab's Agent types: what the launcher said, the column map, the Save rule and body.
import { describe, expect, it } from "vitest";
import {
  agentsPath,
  columnRows,
  example,
  formBriefs,
  formDrops,
  formOf,
  removeRole,
  renameRole,
  saveBody,
  saveRefusal,
  stateLine,
  toYaml,
  usable,
  who,
  withoutUse,
  type ProjectAgentsData,
} from "./projectAgents";

const data = (over: Partial<ProjectAgentsData> = {}): ProjectAgentsData => ({
  project: "acme/x",
  file: ".busyyaks/agents.yml",
  path: "/srv/acme/x/.busyyaks/agents.yml",
  text: "use: [copywriter]\n",
  sha: "abc",
  error: null,
  columns: [
    { key: "backlog", label: "Backlog", type: "parked" },
    { key: "todo", label: "To do", type: "queued" },
    { key: "docs", label: "Docs", type: "working" },
    { key: "done", label: "Done", type: "done" },
  ],
  types: [
    { key: "worker", label: "Worker", opt_in: false },
    { key: "copywriter", label: "Copywriter", opt_in: true },
  ],
  presets: ["copywriter", "researcher"],
  launches: {
    state: "loaded",
    reason: null,
    agents: {
      use: ["copywriter"],
      roles: { changelog: { label: "C", like: "worker" } },
      columns: { docs: "copywriter" },
    },
  },
  briefs: { changelog: true },
  roles: ["changelog"],
  ...over,
});

describe("project agent types", () => {
  it("words each launcher answer, never guessing a state", () => {
    expect(stateLine(data().launches)).toEqual({
      text: "loaded · use copywriter · 1 role · 1 column mapped",
      tone: "ok",
    });
    expect(stateLine({ state: "left", reason: "the repo is not trusted", agents: null })).toEqual({
      text: "not read at launch · the repo is not trusted",
      tone: "warn",
    });
    expect(stateLine({ state: "refused", reason: "unknown keys colums", agents: null }).tone).toBe("bad");
    expect(stateLine({ state: "unknown", reason: "launcher down", agents: null }).text).toMatch(/did not answer/);
    expect(stateLine({ state: "none", reason: null, agents: null }).tone).toBe("muted");
  });

  it("maps every board column to its type or role, any when none is named", () => {
    expect(columnRows(data()).map((r) => [r.key, r.takes])).toEqual([
      ["backlog", "any"],
      ["todo", "any"],
      ["docs", "copywriter"],
      ["done", "any"],
    ]);
  });

  it("starts a new file from the board's own work columns and opt-in types, all commented", () => {
    const t = example(data());
    expect(t).toContain("# use: [copywriter]");
    expect(t).toContain("#   docs: worker");
    expect(t).not.toContain("backlog:");
    expect(t.split("\n").every((l) => l.startsWith("#"))).toBe(true);
  });

  it("Save is off with its reason; the body sends the whole file, its sha and the new briefs", () => {
    const d = data();
    expect(saveRefusal("use: [copywriter]\n", d.text, [], d)).toBe("nothing changed");
    expect(saveRefusal("x: 1\n", d.text, [], d)).toBeNull();
    expect(saveRefusal("x", d.text, [{ role: "Bad", body: "b" }], d)).toMatch(/must match/);
    expect(saveRefusal("x", d.text, [{ role: "changelog", body: "b" }], d)).toMatch(/exists already/);
    expect(saveRefusal("x", d.text, [{ role: "notes", body: " " }], d)).toMatch(/brief of notes is empty/);
    expect(saveRefusal("", d.text, [{ role: "notes", body: "b" }], d)).toMatch(/removing the file takes no briefs/);
    expect(saveRefusal("x", d.text, [], data({ error: "not UTF-8" }))).toBe("not UTF-8");
    expect(saveBody("roles: {}\n", d, [{ role: " notes ", body: "Write notes.\n" }])).toEqual({
      base: "abc",
      text: "roles: {}\n",
      briefs: { notes: "Write notes.\n" },
    });
    expect(saveBody("  ", d, []).text).toBeNull();
    // QA round 4: a role dropped with its brief in one save
    expect(saveRefusal(d.text!, d.text, [], d, ["changelog"])).toBeNull();
    expect(saveRefusal("x", d.text, [{ role: "changelog", body: "b" }], d, ["changelog"])).toMatch(/in one save/);
    expect(saveBody("columns: {}\n", d, [], ["changelog"]).briefs).toEqual({ changelog: null });
    expect(agentsPath("acme/x y")).toBe("/api/projects/acme/x%20y/agents");
  });
});

describe("the form", () => {
  it("is built from what the launcher loaded; a board with no file starts empty; any other state edits YAML only", () => {
    expect(formOf(data()).form).toEqual({
      use: ["copywriter"],
      roles: [{ name: "changelog", label: "C", like: "worker", brief: "", disk: true }],
      columns: { docs: "copywriter" },
    });
    expect(formOf(data({ launches: { state: "none", reason: null, agents: null } })).form).toEqual({
      use: [],
      roles: [],
      columns: {},
    });
    const left = formOf(data({ launches: { state: "left", reason: "not trusted", agents: null } }));
    expect(left.form).toBeNull();
    expect(left.why).toContain("not trusted");
    expect(formOf(data({ error: "not UTF-8" })).why).toBe("not UTF-8");
  });
  it("writes the whole file, every scalar quoted (a role named `on` stays a string); nothing named = no file", () => {
    const f = {
      use: ["copywriter"],
      roles: [{ name: "on", label: 'Say "hi"', like: "worker", brief: "", disk: false }],
      columns: { docs: "on", todo: "" },
    };
    expect(toYaml(f)).toBe(
      'use: ["copywriter"]\nroles:\n  "on": {label: "Say \\"hi\\"", like: "worker"}\ncolumns:\n  "docs": "on"\n',
    );
    expect(toYaml({ use: [], roles: [], columns: { docs: "" } })).toBe("");
  });
  it("a new role carries its brief; a role removed takes its brief on disk with it", () => {
    const d = data();
    const f = formOf(d).form!;
    const added = {
      ...f,
      roles: [...f.roles, { name: "notes", label: "N", like: "worker", brief: "write notes", disk: false }],
    };
    expect(formBriefs(added, d)).toEqual([{ role: "notes", body: "write notes" }]);
    expect(formDrops(added, d)).toEqual([]);
    expect(formDrops(removeRole(f, 0), d)).toEqual(["changelog"]);
  });
  it("renaming or removing a role follows it into the columns; an opt-in type turned off leaves every place", () => {
    const f = {
      use: ["copywriter"],
      roles: [{ name: "r", label: "R", like: "copywriter", brief: "", disk: false }],
      columns: { a: "r", b: "copywriter", c: "worker" },
    };
    expect(renameRole(f, 0, "s").columns).toEqual({ a: "s", b: "copywriter", c: "worker" });
    expect(removeRole(f, 0).columns).toEqual({ b: "copywriter", c: "worker" });
    expect(withoutUse(f, "copywriter")).toEqual({ use: [], roles: [], columns: { c: "worker" } });
  });
  it("offers an opt-in type only while the board uses it; a role wears its type's face", () => {
    const d = data();
    const f = formOf(d).form!;
    expect(usable(d, f).map((t) => t.key)).toEqual(["worker", "copywriter"]);
    expect(usable(d, { ...f, use: [] }).map((t) => t.key)).toEqual(["worker"]);
    expect(who(d, f, "changelog")).toEqual({ type: "worker", label: "C", role: "changelog" });
    expect(who(d, f, "copywriter")).toEqual({ type: "copywriter", label: "Copywriter", role: null });
  });
});
