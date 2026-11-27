import { describe, expect, it } from "vitest";
import {
  agentPath,
  bytes,
  changedPaths,
  changes,
  checkoutLine,
  deletedInGit,
  fieldRefusal,
  fileName,
  formOf,
  gitTag,
  globalSkills,
  kindOf,
  launchLine,
  leaveRefusal,
  limit,
  modeOf,
  newRefRefusal,
  newSkillRefusal,
  newSkillText,
  nextForm,
  projectSkills,
  rulesPath,
  saveRefusal,
  saveStatus,
  shellLine,
  skillFront,
  stale,
  toDraft,
  typeLayers,
  withMode,
  type ProjectRulesData,
  type RuleFile,
} from "./projectRules";

const rule = (path: string, body: string): RuleFile => ({
  body,
  sha: `sha-of-${body.trim()}`,
  eol: "lf",
  ...(kindOf(path) as Pick<RuleFile, "kind" | "type" | "skill">),
  mode: kindOf(path).kind === "agent" ? modeOf(body) : null,
});

const data = (files: Record<string, string> = {}, max = 64): ProjectRulesData => {
  const loaded = Object.fromEntries(Object.entries(files).map(([p, body]) => [p, rule(p, body)]));
  return {
    project: "group/app",
    dir: ".busyyaks/skills",
    path: "/home/op/projects/app/.busyyaks/skills",
    types: [
      { key: "lead", label: "Team lead", under: null, takes: ["queued", "working"], standalone: false },
      { key: "worker", label: "Worker", under: "lead", takes: [], standalone: false },
    ],
    roles: [],
    files: loaded,
    creatable: ["agents/lead.md", "agents/worker.md"].filter((p) => !(p in loaded)),
    errors: {},
    git: {},
    git_error: null,
    max_bytes: max,
    launches: { state: "loaded", reason: null, budget: null, replace_budget: null, layers: null, checkout: false },
    global: null,
    global_error: null,
  };
};
const off = { reason: null, budget: null, checkout: false } as const;
const SKILL = "---\nname: reviewer\ndescription: our review brief\n---\n# ours\n";

describe("projectRules", () => {
  it("the API path keeps a nested slug's slash; a path is a file of the repo's .busyyaks/skills", () => {
    expect(rulesPath("group/my app")).toBe("/api/projects/group/my%20app/agent-rules");
    expect(fileName(data(), "agents/worker.md")).toBe(".busyyaks/skills/agents/worker.md");
    expect(kindOf("agents/lead.md")).toEqual({ kind: "agent", type: "lead" });
    expect(kindOf("reviewer/SKILL.md")).toEqual({ kind: "skill", skill: "reviewer" });
    expect(kindOf("reviewer/checklist.md")).toEqual({ kind: "skill_ref", skill: "reviewer" });
  });

  it("every file in a project's .busyyaks is editable in the web: each file gets an editor, every type's agents file too", () => {
    const d = data({ "agents/worker.md": "Run e2e.\n", "reviewer/SKILL.md": SKILL, "reviewer/checklist.md": "- a\n" });
    expect(toDraft(d)).toEqual({
      "agents/worker.md": "Run e2e.\n",
      "reviewer/SKILL.md": SKILL,
      "reviewer/checklist.md": "- a\n",
      "agents/lead.md": "",
    });
    expect(projectSkills(toDraft(d))).toEqual(["reviewer"]);
  });

  it("a save sends only the changed files, each against the sha the editor loaded; new files with base null", () => {
    const d = data({ "agents/lead.md": "Plan.\n", "reviewer/SKILL.md": SKILL });
    expect(changes(toDraft(d), d)).toEqual({});
    const draft = { ...toDraft(d), "agents/lead.md": "Plan twice.\n", "reviewer/notes.md": "n\n" };
    expect(changes(draft, d)).toEqual({
      "agents/lead.md": { base: "sha-of-Plan.", body: "Plan twice.\n" },
      "reviewer/notes.md": { base: null, body: "n\n" },
    });
  });

  it("a removed file is sent as body null; a blank agents editor removes its file; a blank new one is no change", () => {
    const d = data({ "agents/lead.md": "Plan.\n", "reviewer/SKILL.md": SKILL });
    const draft = { ...toDraft(d), "reviewer/SKILL.md": null, "agents/lead.md": "  \n", "agents/worker.md": " " };
    expect(changes(draft, d)).toEqual({
      "reviewer/SKILL.md": { base: "sha-of-" + SKILL.trim(), body: null },
      "agents/lead.md": { base: "sha-of-Plan.", body: null },
    });
  });

  it("a file that cannot be edited here (a symlink, too big) is never part of a save", () => {
    const d = { ...data({ "agents/lead.md": "x\n" }), errors: { "agents/lead.md": "is a symlink" } };
    expect(changedPaths({ "agents/lead.md": "typed", "agents/worker.md": "" }, d)).toEqual([]);
  });

  it("an agents file adds by default and replaces with `mode: replace`; the switch writes or drops the frontmatter", () => {
    expect(modeOf("Plan.\n")).toBe("add");
    expect(modeOf("---\nmode: replace\n---\nPlan.\n")).toBe("replace");
    expect(modeOf("---\nmode: add\n---\nPlan.\n")).toBe("add");
    expect(modeOf("---\nmode: swap\n---\nPlan.\n")).toBeNull();
    expect(modeOf("---\nname: x\n---\n")).toBeNull();
    expect(withMode("Plan.\n", "replace")).toBe("---\nmode: replace\n---\nPlan.\n");
    expect(withMode("---\nmode: replace\n---\nPlan.\n", "add")).toBe("Plan.\n");
    expect(withMode("---\nmode: add\n---\nPlan.\n", "replace")).toBe("---\nmode: replace\n---\nPlan.\n");
  });

  it("counts UTF-8 bytes, like the server; an agents file is held to its type's budget for its mode", () => {
    expect(bytes("żółw")).toBe(7);
    const d = {
      ...data({}, 65536),
      launches: {
        ...off,
        state: "loaded" as const,
        budget: { lead: 100, worker: 70000 },
        replace_budget: { lead: 300 },
      },
    };
    expect(limit(d, "lead", "add")).toEqual({ bytes: 100, launch: true });
    expect(limit(d, "lead", "replace")).toEqual({ bytes: 300, launch: true });
    expect(limit(d, "worker", "add")).toEqual({ bytes: 65536, launch: false });
    const draft = toDraft(d);
    expect(fieldRefusal("agents/lead.md", "x".repeat(101), draft, d)).toBe(
      "101 bytes · over 100: a lead launch would be refused",
    );
    expect(fieldRefusal("agents/lead.md", `---\nmode: replace\n---\n${"x".repeat(200)}`, draft, d)).toBeNull();
    expect(fieldRefusal("agents/lead.md", "---\nmode: swap\n---\nx", draft, d)).toMatch(/exactly `mode: add`/);
  });

  it("a skill file holds text, its SKILL.md a frontmatter naming its dir, the whole skill within max_bytes", () => {
    const d = data({}, 200);
    const draft = { "reviewer/SKILL.md": SKILL };
    expect(fieldRefusal("reviewer/SKILL.md", SKILL, draft, d)).toBeNull();
    expect(fieldRefusal("reviewer/SKILL.md", " ", draft, d)).toBe("a skill file holds text: Remove it instead");
    expect(fieldRefusal("reviewer/SKILL.md", "# no front\n", draft, d)).toMatch(/needs its frontmatter/);
    expect(fieldRefusal("reviewer/SKILL.md", SKILL.replace("name: reviewer", "name: other"), draft, d)).toBe(
      "name other must be its dir's reviewer",
    );
    const big = { ...draft, "reviewer/a.md": "x".repeat(200) };
    expect(fieldRefusal("reviewer/a.md", "x".repeat(200), big, d)).toMatch(
      /the reviewer skill is \d+ bytes · over 200/,
    );
    expect(skillFront("---\nname: a\n---\n")).toBe("SKILL.md's frontmatter needs name and description");
  });

  it("refuses a !`…` line, naming it", () => {
    expect(shellLine("a\nsee !`id`\n")).toBe(2);
    expect(fieldRefusal("agents/lead.md", "a\nsee !`id`\n", {}, data())).toBe("line 2: !`…` runs as a shell command");
    expect(shellLine("plain `code`")).toBeNull();
  });

  it("Save is off with the reason: nothing changed, a bad field, a reference file left without its SKILL.md", () => {
    const d = data({ "agents/lead.md": "Plan.\n", "reviewer/SKILL.md": SKILL, "reviewer/a.md": "a\n" });
    expect(saveRefusal(toDraft(d), d)).toBe("nothing changed");
    expect(saveRefusal({ ...toDraft(d), "agents/worker.md": "!`x`" }, d)).toBe(
      "agents/worker.md: line 1: !`…` runs as a shell command",
    );
    expect(saveRefusal({ ...toDraft(d), "reviewer/SKILL.md": null }, d)).toBe("reviewer: a skill needs its SKILL.md");
    expect(saveRefusal({ ...toDraft(d), "reviewer/SKILL.md": null, "reviewer/a.md": null }, d)).toBeNull();
  });

  it("a new skill: its name checked, its SKILL.md a copy of the global skill of that name (an override) or a template", () => {
    const d = data();
    d.global = {
      agent_types: [],
      files: [
        {
          path: "skills/busyyaks/reviewer/SKILL.md",
          source: "busyyaks",
          kind: "skill",
          load: "on_demand",
          skill: "reviewer",
          description: "the brief",
          bytes: 10,
          html: "",
          body: "---\nname: reviewer\ndescription: the brief\n---\nbusyyaks's\n",
          replaced_by: null,
        },
      ],
    };
    expect(globalSkills(d).map((s) => s.name)).toEqual(["reviewer"]);
    expect(newSkillText("reviewer", d)).toBe("---\nname: reviewer\ndescription: the brief\n---\nbusyyaks's\n");
    expect(newSkillText("deploy", d)).toMatch(/^---\nname: deploy\ndescription: /);
    expect(newSkillRefusal("Deploy", {})).toMatch(/a-z, 0-9/);
    expect(newSkillRefusal("core", {})).toMatch(/busyyaks's own/);
    expect(newSkillRefusal("reviewer", { "reviewer/SKILL.md": SKILL })).toBe(
      "reviewer is a skill of this project already",
    );
    expect(newSkillRefusal("deploy", {})).toBeNull();
    expect(newRefRefusal("reviewer", "a b.md", {})).toMatch(/<name>\.md/);
    expect(newRefRefusal("reviewer", "SKILL.md", {})).toMatch(/<name>\.md/);
    expect(newRefRefusal("reviewer", "a.md", { "reviewer/a.md": "x" })).toBe("reviewer/a.md exists");
  });

  it("per type, what a launch stages: each global file added to or replaced, from the launcher's composition", () => {
    const d = data({ "agents/lead.md": "---\nmode: replace\n---\nours\n" });
    expect(typeLayers(d, "lead")).toBe("launch view unknown · no answer from the launcher");
    d.launches.layers = {
      lead: {
        start: [
          { path: "skills/busyyaks/core/SKILL.md", source: "busyyaks", kind: "core", mode: null, replaced_by: null },
          {
            path: "skills/busyyaks/agents/lead.md",
            source: "busyyaks",
            kind: "agent",
            mode: "add",
            replaced_by: "project",
          },
          {
            path: ".busyyaks/skills/agents/lead.md",
            source: "project",
            kind: "agent",
            mode: "replace",
            replaced_by: null,
          },
        ],
        on_demand: [],
      },
    };
    expect(typeLayers(d, "lead")).toEqual([
      { path: "skills/busyyaks/core/SKILL.md", source: "busyyaks", state: "added", by: null },
      { path: "skills/busyyaks/agents/lead.md", source: "busyyaks", state: "replaced", by: "project" },
      { path: ".busyyaks/skills/agents/lead.md", source: "project", state: "added", by: null },
    ]);
  });

  it("after a save: the files written, read at the next launch", () => {
    expect(saveStatus(null, ["agents/lead.md", "reviewer/SKILL.md"], "nothing changed")).toEqual({
      tone: "ok",
      text: "written · agents/lead.md, reviewer/SKILL.md · read at the next launch",
      reload: false,
    });
  });
  it("a file changed on disk since it was read (409) is a conflict that offers the newest", () => {
    const text = ".busyyaks/skills/agents/lead.md changed on disk since the editor read it: nothing written";
    expect(saveStatus({ status: 409, text }, null, null)).toEqual({
      tone: "bad",
      text: `conflict · ${text}`,
      reload: true,
    });
  });
  it("a refusal (422) shows the server's reason verbatim; other statuses as they are; idle = why Save is off", () => {
    expect(saveStatus({ status: 422, text: "x" }, null, null)).toEqual({
      tone: "bad",
      text: "refused · x",
      reload: false,
    });
    expect(saveStatus({ status: 503, text: "writer not reachable" }, null, null).text).toBe(
      "503 · writer not reachable",
    );
    expect(saveStatus({ status: 0, text: "Failed to fetch" }, null, null).text).toBe("no answer · Failed to fetch");
    expect(saveStatus(null, null, "nothing changed")).toEqual({
      tone: "muted",
      text: "nothing changed",
      reload: false,
    });
  });
  it("says what a launch does with the files: loaded · left (and why) · refused · unknown", () => {
    expect(launchLine({ ...off, state: "loaded" }).text).toBe("read at launch · busyyaks-launched sessions only");
    expect(launchLine({ ...off, state: "none" }).tone).toBe("muted");
    expect(launchLine({ ...off, state: "left", reason: "not trusted" }).text).toBe(
      "left out of launches · not trusted",
    );
    expect(launchLine({ ...off, state: "refused", reason: "skills: x" }).text).toBe("launches refused · skills: x");
    expect(launchLine({ ...off, state: "unknown", reason: "down" }).text).toBe("launch state unknown · down");
  });
  it("a read of the server becomes the form only while nothing is edited: typing is never overwritten", () => {
    const first = data({ "agents/lead.md": "Plan.\n" });
    const newer = data({ "agents/lead.md": "Plan twice.\n" });
    expect(nextForm(null, first)).toEqual({
      loaded: first,
      draft: { "agents/lead.md": "Plan.\n", "agents/worker.md": "" },
    });
    expect(nextForm(formOf(first), newer).loaded).toBe(newer);
    const typing = { loaded: first, draft: { "agents/lead.md": "Plan.\n", "agents/worker.md": "#" } };
    expect(nextForm(typing, newer)).toBe(typing);
    expect(stale(typing, newer)).toEqual(["agents/lead.md"]);
    expect(stale(typing, first)).toEqual([]);
  });
  it("git: tracked, uncommitted, ignored, and a file removed but still in git is named", () => {
    expect(gitTag("committed", false)).toEqual({ tone: "muted", text: "tracked by git · committed" });
    expect(gitTag("committed", true)?.text).toBe("tracked by git · Save leaves an uncommitted change");
    expect(gitTag("ignored", false)?.text).toBe("ignored by git · never committed with the repo");
    expect(gitTag(undefined, true)).toBeNull();
    const d = {
      ...data({ "agents/lead.md": "x\n" }),
      git: { "reviewer/SKILL.md": "deleted" as const, "agents/lead.md": "committed" as const },
    };
    expect(deletedInGit(d)).toEqual(["reviewer/SKILL.md"]);
  });
  it("leaving the Settings tab with unsaved editors is refused and said; any other move goes", () => {
    expect(leaveRefusal("settings", "board", 2)).toBe("2 unsaved rule files · Save or Discard first");
    expect(leaveRefusal("settings", "board", 0)).toBeNull();
    expect(leaveRefusal("board", "settings", 2)).toBeNull();
  });
  it("busyyaks's own checkout as a project: says that yaks update refuses uncommitted tracked files, naming them", () => {
    const own = {
      ...data({ "agents/worker.md": "w\n" }),
      launches: { ...off, state: "loaded" as const, checkout: true },
    };
    expect(checkoutLine(own)).toMatch(/refuses it while a tracked file here is uncommitted/);
    expect(checkoutLine({ ...own, git: { "agents/worker.md": "modified" } })).toBe(
      "busyyaks's own checkout · yaks update is refused until agents/worker.md is committed",
    );
    expect(checkoutLine(data())).toBeNull();
    expect(agentPath("lead")).toBe("agents/lead.md");
  });
});
