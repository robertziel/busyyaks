// Settings → Agent rules, in the operator's words: "what's sub team? where is lead? where are global markdowns for all
// projects? … where in web app?", "Do one column per file", "All must be editable, also global", "Missing teamlead,
// reviewer?". The derivations (names, purposes, groups, budgets, the form) and the page rendered as markup.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { AgentRulesView } from "../routes/AgentRulesSettings";
import {
  anchor,
  budget,
  changedPaths,
  changes,
  fieldRefusal,
  groups,
  purpose,
  role,
  saveRefusal,
  stripFront,
  toDraft,
  typeTitle,
  uncommitted,
  what,
  whoGets,
  type AgentRulesData,
  type AgentTypeInfo,
  type GlobalFile,
} from "./agentRules";

const CORE = "skills/busyyaks/core/SKILL.md";
const LEAD = "skills/busyyaks/agents/lead.md";
const types: AgentTypeInfo[] = [
  { key: "lead", label: "Team lead", under: null, takes: ["queued", "working", "review", "gate"], standalone: false },
  { key: "worker", label: "Worker", under: "lead", takes: [], standalone: false },
  { key: "team", label: "Sub team", under: "lead", takes: [], standalone: false },
  { key: "plain", label: "Plain", under: null, takes: [], standalone: true },
].map((t) => ({
  ...t,
  start: [CORE, ...(t.key === "plain" ? [] : [`skills/busyyaks/agents/${t.key}.md`])],
  on_demand: ["reviewer", "local-repo"],
  start_bytes: 9000,
  budget: 23000,
}));
const f = (path: string, over: Partial<GlobalFile> = {}): GlobalFile => ({
  path,
  source: "busyyaks",
  kind: "agent",
  load: "start",
  skill: null,
  description: null,
  type: null,
  exists: true,
  bytes: 100,
  sha: `sha-${path}`,
  eol: "lf",
  body: "# x\n",
  html: "<h1>x</h1>",
  git: "committed",
  error: null,
  ...over,
});
const data = (over: Partial<AgentRulesData> = {}): AgentRulesData => ({
  checkout: { host: "/home/op/projects/busyyaks", mount: "/projects/busyyaks", error: null },
  limits: { max_bytes: 65536, max_start_bytes: 32768, project: "allow", local_dir: "skills-local" },
  agent_types: types,
  files: [
    f(CORE, {
      kind: "core",
      skill: "core",
      description: "How busyyaks sessions work",
      body: "---\nname: core\n---\n# core\n",
    }),
    f(LEAD, { type: "lead", body: "# Lead\n" }),
    f("skills/busyyaks/agents/worker.md", { type: "worker" }),
    f("skills/busyyaks/agents/team.md", { type: "team" }),
    f("skills/busyyaks/agents/plain.md", {
      type: "plain",
      exists: false,
      bytes: 0,
      sha: null,
      body: "",
      html: "",
      git: undefined,
    }),
    f("skills/busyyaks/reviewer/SKILL.md", {
      kind: "skill",
      load: "on_demand",
      skill: "reviewer",
      description: "The reviewer agent's brief",
      body: "---\nname: reviewer\ndescription: d\n---\n# r\n",
    }),
    f("skills-local/local-repo/SKILL.md", {
      source: "deployment",
      kind: "skill",
      load: "on_demand",
      skill: "local-repo",
      description: "The card flow of a mirror",
      body: "---\nname: local-repo\ndescription: d\n---\n# l\n",
    }),
    f("skills-local/agents/lead.md", {
      source: "deployment",
      type: "lead",
      exists: false,
      bytes: 0,
      sha: null,
      body: "",
      html: "",
      git: undefined,
    }),
  ],
  git_error: null,
  ...over,
});

const render = (d: AgentRulesData, open: string[] = []) =>
  renderToStaticMarkup(
    createElement(
      MemoryRouter,
      null,
      createElement(AgentRulesView, {
        data: d,
        form: { loaded: d, draft: toDraft(d) },
        open,
        saving: false,
        status: { tone: "muted", text: "" },
        onToggle: () => {},
        onChange: () => {},
      }),
    ),
  );

describe("agent types are named by what they are", () => {
  it("the lead's rules are titled Team lead, never Launch", () => {
    const lead = types[0]!;
    expect(typeTitle(lead)).toBe("Team lead");
    expect(what(data().files[1]!, types)).toBe("Team lead rules");
    expect(render(data())).not.toMatch(/>Launch</);
  });
  it("each type says what it is, from its config: lead · under the lead · plain", () => {
    expect(types.map((t) => role(t, types))).toEqual(["lead", "under", "under", "standalone"]);
    expect(purpose(types[0]!, types)).toBe(
      "owns the board · adopts every ownerless card in queued · working · review · gate columns · starts Worker, Sub team",
    );
    expect(purpose(types[2]!, types)).toBe(
      "runs only while the Team lead runs, on its launcher · adopts no card on its own",
    );
    expect(purpose(types[3]!, types)).toMatch(/^a plain session · no lead needed/);
  });
});

describe("the operator can read every global markdown, in the order a launch stages it", () => {
  it("one card per file, the team lead and the reviewer each their own, nothing hidden", () => {
    const html = render(data());
    for (const file of data().files) expect(html).toContain(`id="${anchor(file.path)}"`);
    expect(html.match(/class="card rc/g)).toHaveLength(data().files.length);
    expect(html).toContain("on-demand skill · reviewer");
  });
  it("grouped by who gets them: every session · per agent type · on demand · this deployment", () => {
    expect(groups(data()).map((g) => [g.title, g.files.map((x) => x.path)])).toEqual([
      ["Every session", [CORE]],
      [
        "Per agent type",
        [LEAD, "skills/busyyaks/agents/worker.md", "skills/busyyaks/agents/team.md", "skills/busyyaks/agents/plain.md"],
      ],
      ["On demand", ["skills/busyyaks/reviewer/SKILL.md"]],
      ["This deployment", ["skills-local/agents/lead.md", "skills-local/local-repo/SKILL.md"]],
    ]);
  });
  it("each type lists its entry skill's files in launch order, then the project's own file", () => {
    const html = render(data());
    const lead = html.slice(html.indexOf("Team lead"), html.indexOf("Worker</b>"));
    expect(lead.indexOf(CORE)).toBeLessThan(lead.indexOf(LEAD));
    expect(lead).toContain("this project&#x27;s <code>.busyyaks/skills/agents/lead.md</code> — adds, or with");
    expect(lead).toContain("<code>mode: replace</code> replaces the agents files above");
  });
  it("each on-demand skill says who dispatches it and when; a file a later layer replaced says so", () => {
    const d = data();
    const skill = { ...d.files[5]!, dispatch: "the worker, on every pushed head" };
    expect(whoGets(skill, types)).toBe("dispatched by the worker, on every pushed head");
    expect(whoGets({ ...skill, replaced_by: "deployment" }, types)).toBe(
      "replaced by this deployment's file of the same name · in no launch",
    );
  });
  it("who gets a file: every session for the core, a type's sessions for its file, on demand for a skill", () => {
    const d = data();
    expect(whoGets(d.files[0]!, types)).toBe("every busyyaks session, at start");
    expect(whoGets(d.files[1]!, types)).toBe("every Team lead session, at start");
    expect(whoGets(d.files[5]!, types)).toMatch(/^on demand/);
    expect(whoGets(d.files[4]!, types)).toBe("no file yet · Save makes it for every Plain session");
  });
  it("an open card shows the server's render, and where the file is committed", () => {
    const html = render(data(), [anchor(LEAD)]);
    expect(html).toContain("<h1>x</h1>");
    expect(html).toContain("committed in the busyyaks repo: skills/busyyaks/agents/lead.md — read at every launch");
  });
});

describe("all must be editable, also global", () => {
  it("the operator edits the team lead's global rules in the web: Save sends that file against its sha", () => {
    const d = data();
    const draft = { ...toDraft(d), [LEAD]: "# Lead\n- one card at a time\n" };
    expect(changedPaths(draft, d)).toEqual([LEAD]);
    expect(changes(draft, d)).toEqual({ [LEAD]: { base: `sha-${LEAD}`, body: "# Lead\n- one card at a time\n" } });
    expect(saveRefusal(draft, d)).toBeNull();
  });
  it("the reviewer skill is editable, its frontmatter kept", () => {
    const d = data();
    const rev = d.files[5]!;
    expect(fieldRefusal(rev, "# no frontmatter\n", d)).toBe(
      "SKILL.md needs its frontmatter (--- name, description ---)",
    );
    expect(fieldRefusal(rev, "", d)).toMatch(/cannot be blank/);
    expect(fieldRefusal(rev, "---\nname: reviewer\ndescription: d\n---\nmore\n", d)).toBeNull();
  });
  it("a missing agents file is made by typing in its empty card; blanking an agents file removes it", () => {
    const d = data();
    const draft = { ...toDraft(d), "skills/busyyaks/agents/plain.md": "PLAIN\n", [LEAD]: "" };
    expect(changes(draft, d)).toEqual({
      "skills/busyyaks/agents/plain.md": { base: null, body: "PLAIN\n" },
      [LEAD]: { base: `sha-${LEAD}`, body: null },
    });
  });
  it("a shell line is refused before the round trip", () => {
    expect(fieldRefusal(data().files[1]!, "ok\nrun !`date`\n", data())).toBe("line 2: !`…` runs as a shell command");
  });
  it("a checkout the writer cannot reach: Save is off, saying why", () => {
    const d = data({ checkout: { host: "/opt/busyyaks", mount: null, error: "not under PROJECTS_ROOT" } });
    expect(saveRefusal({ ...toDraft(d), [LEAD]: "x\n" }, d)).toBe("not writable here · not under PROJECTS_ROOT");
    expect(render(d)).toContain("read-only here · not under PROJECTS_ROOT");
  });
  it("after a save the uncommitted global files are listed: yaks update refuses until they are committed", () => {
    const d = data();
    d.files[1]!.git = "modified";
    const u = uncommitted(d);
    expect(u).toEqual({
      paths: [LEAD],
      text: "uncommitted change in the busyyaks repo — `yaks update` refuses until it is committed",
    });
    expect(render(d)).toContain(
      "uncommitted change in the busyyaks repo — `yaks update` refuses until it is committed · " + LEAD,
    );
  });
});

describe("one number per card: the launch budget", () => {
  it("an agents file may hold max_start_bytes less the rest of its type's entry skill; the breakdown is the tooltip", () => {
    const d = data();
    const lead = d.files[1]!; // 7 bytes in a 9000-byte entry skill
    expect(budget(lead, d)).toEqual({
      max: 32768 - (9000 - 7),
      tip: "skills.max_start_bytes 32,768 − the rest of the Team lead entry skill 8,993",
    });
    expect(fieldRefusal(lead, "x".repeat(32768), d)).toMatch(/over 23,775: a launch would be refused$/);
  });
  it("an on-demand skill's file may hold max_bytes less its skill's other files", () => {
    expect(budget(data().files[5]!, data()).max).toBe(65536);
  });
});

describe("the critic's fixes", () => {
  it("a frontmatter counts only at the very start of a SKILL.md, as the server reads it", () => {
    const d = data();
    const rev = d.files[5]!;
    const late = "# intro\n---\nname: reviewer\ndescription: d\n---\nbody\n";
    expect(fieldRefusal(rev, late, d)).toBe("SKILL.md needs its frontmatter (--- name, description ---)");
    expect(stripFront(late)).toBe(late);
    expect(stripFront("---\nname: core\n---\n# core\n")).toBe("# core\n");
  });
  it("Preview and Write are toggle buttons: the pressed one is the view shown", () => {
    const html = render(data(), [anchor(LEAD)]);
    expect(html).toMatch(/<button type="button" aria-pressed="true">Preview<\/button>/);
    expect(html).toMatch(/<button type="button" aria-pressed="false">Write<\/button>/);
    expect(html).not.toContain('role="tab"');
  });
});
