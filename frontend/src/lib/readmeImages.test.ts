/// <reference types="node" />
// scripts/readme-images/rename.js (the README live captures' rename rule + leak gate, outside the bundle; run by
// scripts/readme-images/capture-live.js in node and in the captured page) on synthetic strings: hosts with and without a scheme, IPv4, owner/repo pairs, every spelling of another
// project's name (short words too, any case), the operator's name, emails — is renamed by the rule, and the gate
// refuses each one when it is left in place. No real name appears here.
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";

const SOURCE = readFileSync(new URL("../../../scripts/readme-images/rename.js", import.meta.url), "utf8");
const SAMPLES = readFileSync(new URL("../../../scripts/readme-images/samples.js", import.meta.url), "utf8");

type Spec = {
  own: Record<string, string>;
  others: string[];
  groups: string[];
  ownRepos: string[];
  terms: string[];
  people: string[];
};
type Leak = [string, string];
type Rule = {
  makeRenamer(spec: Spec): { text(s: string): string; json(v: unknown): unknown };
  leaks(text: string, spec: Spec): Leak[];
  specFrom(input: {
    slugs: string[];
    groups: string[];
    repos: string[];
    own: string;
    keep: string[];
    ownRepos: string[];
    terms: string[];
    people: string[];
  }): Spec;
  mergedRepos(today: unknown): string[];
  wbrRuns(children: Piece[]): { nodes: number[]; text: string }[];
  renameRuns(children: Piece[], rename: (s: string) => string): Map<number, string>;
};
type Piece = { text: string } | { wbr: true } | { element: true };

function load(): Rule {
  const module = { exports: {} as Rule };
  runInNewContext(SOURCE, { module });
  return module.exports;
}

const rule = load();
const OWN_REPOS = ["pubowner/busyyaks", "pubowner/busyyaks_agents_kanban_module"];
const spec = rule.specFrom({
  slugs: ["busyyaks_work", "busyyaks_engine", "busyyaks_tool_mirror", "auth", "proj_one", "grp/deep-repo", "max"],
  groups: ["grp", "zone"],
  repos: ["pubowner/busyyaks", "pubowner/busyyaks_private_mirror", "someone/tool", "pubowner/busyyaks_work"],
  own: "busyyaks_work",
  keep: ["busyyaks_engine"],
  ownRepos: OWN_REPOS,
  terms: ["secretword", "internal.example.org"],
  people: ["Alex Sample", "Alex", "Sample"],
});
const r = rule.makeRenamer(spec);
const kinds = (text: string) => rule.leaks(text, spec).map(([kind]) => kind);

describe("rename.js: the spec", () => {
  it("keeps busyyaks' own slug and the projects named in keep, renames everything else", () => {
    expect(spec.own).toEqual({ busyyaks_work: "busyyaks" });
    expect(spec.others).toEqual([
      "busyyaks_tool_mirror",
      "auth",
      "proj_one",
      "grp/deep-repo",
      "max",
      "pubowner/busyyaks_private_mirror",
      "someone/tool",
    ]);
  });

  it("refuses an empty term list and a missing operator name", () => {
    const base = {
      slugs: ["x", "y"],
      groups: [],
      repos: [],
      own: "x",
      keep: [],
      ownRepos: ["o/x"],
      terms: ["t"],
      people: ["P"],
    };
    expect(() => rule.specFrom({ ...base, terms: [] })).toThrow(/no term/);
    expect(() => rule.specFrom({ ...base, people: [] })).toThrow(/operator name/);
    expect(() => rule.specFrom({ ...base, own: "z" })).toThrow(/not a project/);
    expect(() => rule.specFrom({ ...base, keep: undefined as unknown as string[] })).toThrow(/keep .* is required/);
    expect(() => rule.specFrom({ ...base, keep: ["z"] })).toThrow(/keep: z is not another project/);
    expect(() => rule.specFrom({ ...base, keep: ["x"] })).toThrow(/keep: x is not another project/);
    expect(() => rule.specFrom({ ...base, ownRepos: [] })).toThrow(/no public repo/);
  });

  it("reads every merged PR's repo, and refuses a Today answer without merged_prs", () => {
    expect(rule.mergedRepos({ merged_prs: [{ repo: "a/b" }, { repo: "c/d" }] })).toEqual(["a/b", "c/d"]);
    expect(() => rule.mergedRepos({})).toThrow(/merged_prs/);
    expect(() => rule.mergedRepos({ merged_prs: [{ title: "x" }] })).toThrow(/merged_prs\[0\] has no repo/);
  });
});

describe("rename.js: text", () => {
  it.each([
    ["box.internal is up", "ci.example.com is up"],
    ["jenkins.corp.lan/job/7", "ci.example.com/job/7"],
    ["https://jenkins.corp.lan/job/7", "https://ci.example.com/job/7"],
    ["10.0.0.5 and 127.0.0.1", "192.0.2.1 and 127.0.0.1"],
    ["ssh -t somebox tmux attach", "ssh -t box tmux attach"],
    ["mail me@host.example.net", "mail operator"],
  ])("a host, an address or an email: %s", (input, output) => {
    expect(r.text(input)).toBe(output);
  });

  it("keeps file names, this machine and GitHub", () => {
    expect(r.text("see app.rb, kanban.yml and 127.0.0.1:3096/x on github.com")).toBe(
      "see app.rb, kanban.yml and 127.0.0.1:3096/x on github.com",
    );
  });

  it("renames every spelling of another project's name, short words too, any case", () => {
    for (const s of ["proj_one", "proj-one", "Proj-One", "grp/deep-repo", "grp_deep_repo", "deep-repo", "deep_repo"])
      expect(r.text(`x ${s} y`)).toMatch(/^x acme[-_]\d+ y$/);
    expect(r.text("the auth provider")).toBe("the acme-2 provider");
    expect(r.text("max 1107")).toBe("acme-5 1107");
    expect(r.text("zone/x and Zone")).toBe("group-2/x and group-2");
  });

  it("shows busyyaks' working repo as busyyaks, never as another project", () => {
    expect(spec.others).not.toContain("pubowner/busyyaks_work");
    expect(r.text("github.com/pubowner/busyyaks_work/pull/4")).toBe("github.com/pubowner/busyyaks/pull/4");
    expect(r.json({ slug: "busyyaks_work" })).toEqual({ slug: "busyyaks_work" });
  });

  it("keeps only the projects named in keep: a busyyaks-prefixed project not named is another project", () => {
    const s2 = rule.specFrom({
      slugs: ["busyyaks_work", "busyyaks_secretplan", "tools/busyyaks_kept"],
      groups: ["tools", "zone"],
      repos: [],
      own: "busyyaks_work",
      keep: ["tools/busyyaks_kept"],
      ownRepos: OWN_REPOS,
      terms: ["secretword"],
      people: ["Alex"],
    });
    expect(s2.others).toEqual(["busyyaks_secretplan"]);
    expect(s2.groups).toEqual(["zone"]);
    const r2 = rule.makeRenamer(s2);
    expect(r2.text("busyyaks_secretplan and busyyaks_kept")).toBe("acme-1 and busyyaks_kept");
    expect(rule.leaks("busyyaks_secretplan", s2).map(([k]) => k)).toContain("project name");
  });

  it("refuses a kept name that carries a private term: keep never exempts a name from the gate", () => {
    const s3 = rule.specFrom({
      slugs: ["busyyaks_work", "busyyaks_secretword_tool"],
      groups: [],
      repos: [],
      own: "busyyaks_work",
      keep: ["busyyaks_secretword_tool"],
      ownRepos: OWN_REPOS,
      terms: ["secretword"],
      people: ["Alex"],
    });
    expect(rule.leaks("on busyyaks_secretword_tool today", s3).map(([k]) => k)).toContain("private term");
  });

  it("maps busyyaks' working repo to the public one only under its public owner", () => {
    expect(r.text("github.com/someone/busyyaks_work/pull/4")).toBe("github.com/acme/acme-repo/pull/4");
    expect(rule.makeRenamer(spec).json({ repo: "someone/busyyaks_work", title: "about it" })).toEqual({
      repo: "someone/busyyaks_work",
      title: "Task 1",
    });
    expect(r.text("github.com/pubowner/busyyaks_work/pull/4")).toBe("github.com/pubowner/busyyaks/pull/4");
  });

  it("never matches an inherited key as busyyaks' working repo", () => {
    expect(r.text("github.com/pubowner/constructor/pull/1")).toBe("github.com/acme/acme-repo/pull/1");
    expect(r.text("github.com/pubowner/toString")).toBe("github.com/acme/acme-repo");
  });

  it("renames busyyaks' working slug, keeps its other projects and its public repos", () => {
    expect(r.text("busyyaks_work_teamlead · busyyaks-work-502")).toBe("busyyaks_teamlead · busyyaks-502");
    expect(r.text("busyyaks_engine")).toBe("busyyaks_engine");
    expect(r.text("github.com/pubowner/busyyaks/pull/9")).toBe("github.com/pubowner/busyyaks/pull/9");
  });

  it("renames every owner/repo that is not busyyaks' public one, bare or behind github.com", () => {
    expect(r.text("github.com/someone/unlisted/pull/3")).toBe("github.com/acme/acme-repo/pull/3");
    expect(r.text("github.com/pubowner/busyyaks_private_mirror")).toBe("github.com/acme/acme-repo");
    expect(r.text("merged someone/tool #12")).toMatch(/^merged acme-\d+ #12$/);
    expect(r.text("pubowner/busyyaks_private_mirror")).toMatch(/^acme-\d+$/);
  });

  it("shows busyyaks' public repos by their repo name as text, keeps them whole behind github.com", () => {
    expect(r.text("pubowner/busyyaks #69 merged")).toBe("busyyaks #69 merged");
    expect(r.text("PUBOWNER/busyyaks_agents_kanban_module")).toBe("busyyaks_agents_kanban_module");
    expect(r.text("github.com/pubowner/busyyaks/pull/9")).toBe("github.com/pubowner/busyyaks/pull/9");
    expect(r.text("pubowner/busyyaks_work/pull/4")).toBe("pubowner/busyyaks/pull/4");
    expect(r.text("x pubowner/busyyaks_extra y")).toBe("x pubowner/busyyaks_extra y");
    expect(r.text("merged pubowner/busyyaks.")).toBe("merged busyyaks.");
  });

  it("renames the operator's name and its words as whole words, never inside a longer word", () => {
    expect(r.text("by Alex Sample, thanks alex")).toBe("by Dev Example, thanks Dev Example");
    expect(r.text("Alexander")).toBe("Alexander");
  });
});

describe("rename.js: json", () => {
  it("replaces another project's free text and sessions, keeps busyyaks' own", () => {
    const out = r.json({
      groups: [
        {
          slug: "proj_one",
          sessions: [{ name: "proj_one_teamlead", socket: "default", ssh_attach: "attach proj_one_teamlead" }],
        },
        { slug: "busyyaks_work", cards: [{ title: "Lead-first boards" }] },
      ],
      merged_prs: [{ repo: "someone/tool", title: "Fix the thing" }],
    }) as {
      groups: [
        { slug: string; sessions: [{ name: string; ssh_attach: string }] },
        { slug: string; cards: [{ title: string }] },
      ];
      merged_prs: [{ repo: string; title: string }];
    };
    expect(out.groups[0].slug).toMatch(/^acme-\d+$/);
    expect(out.groups[0].sessions[0].name).toBe("agent_1");
    expect(out.groups[0].sessions[0].ssh_attach).toBe("attach agent_1");
    expect(out.groups[1]).toEqual({ slug: "busyyaks_work", cards: [{ title: "Lead-first boards" }] });
    expect(out.merged_prs[0].title).toBe("Task 1");
  });

  it("renames a session outside every tracked repo and hides its text", () => {
    const fresh = rule.makeRenamer(spec);
    const out = fresh.json({
      groups: [
        {
          label: "outside tracked repos",
          slug: null,
          sessions: [
            {
              key: "default/side_job",
              name: "side_job",
              socket: "default",
              title: "Render the weekly clips",
              terminal_url: "https://term.example.org/#s=side_job&sock=default",
              ssh_attach: "ssh -t host tmux attach -t side_job",
            },
          ],
        },
      ],
    }) as { groups: [{ label: string; sessions: [Record<string, string>] }] };
    const s = out.groups[0].sessions[0];
    expect(out.groups[0].label).toBe("outside tracked repos");
    expect(s.name).toBe("agent_1");
    expect(s.key).toBe("default/agent_1");
    expect(s.title).toBe("Task 1");
    expect(s.ssh_attach).toBe("ssh -t host tmux attach -t agent_1");
    expect(JSON.stringify(out)).not.toContain("side_job");
  });

  it("replaces busyyaks' own text that holds a private term", () => {
    const fresh = rule.makeRenamer(spec);
    expect(fresh.json({ slug: "busyyaks_work", title: "about secretword" })).toEqual({
      slug: "busyyaks_work",
      title: "Task 1",
    });
  });
});

describe("rename.js: a word split by <wbr>", () => {
  // <span>x <b>#1</b>proj_<wbr>one<i>!</i></span>: the Links rail's repo name, a sibling element on each side
  const children: Piece[] = [
    { text: "x " },
    { element: true },
    { text: "proj_" },
    { wbr: true },
    { text: "one" },
    { element: true },
  ];

  it("joins the pieces across a <wbr>, never across an element", () => {
    expect(rule.wbrRuns(children)).toEqual([{ nodes: [2, 4], text: "proj_one" }]);
    expect(rule.wbrRuns([{ text: "a" }, { element: true }, { text: "b" }])).toEqual([]);
    expect(rule.wbrRuns([{ wbr: true }, { text: "alone" }])).toEqual([]);
  });

  it("renames the joined word in its text pieces only, keeping every element and the <wbr>", () => {
    const out = rule.renameRuns(children, (s) => rule.makeRenamer(spec).text(s));
    expect([...out.keys()]).toEqual([2, 4]);
    expect(out.get(2)).toMatch(/^acme-\d+$/);
    expect(out.get(4)).toBe("");
    expect(rule.renameRuns([{ text: "busy" }, { wbr: true }, { text: "yaks" }], (s) => s).size).toBe(0);
  });

  it("is what the gate needs: one text node per piece hides the name, the joined word does not", () => {
    expect(kinds("proj_\none")).not.toContain("project name");
    const words = rule.wbrRuns(children).map((run) => run.text);
    expect(kinds(words.join("\n"))).toContain("project name");
  });
});

describe("rename.js: leaks (the gate)", () => {
  it.each([
    ["a secretword here", "private term"],
    ["see internal.example.org", "private term"],
    ["box.internal", "host"],
    ["jenkins.corp.lan/job/7", "host"],
    ["https://jenkins.corp.lan", "host"],
    ["10.0.0.5", "host"],
    ["me@host.example.net", "email"],
    ["github.com/someone/unlisted", "GitHub repo"],
    ["proj-one", "project name"],
    ["grp_deep_repo", "project name"],
    ["the Auth provider", "project name"],
    ["someone/tool", "project name"],
    ["pubowner/busyyaks_private_mirror", "project name"],
    ["zone", "group name"],
    ["busyyaks_work", "project name"],
    ["by Alex", "operator's name"],
    ["pubowner/busyyaks #69", "owner login"],
    ["merged pubowner/busyyaks.", "owner login"],
  ])("refuses %s", (text, kind) => {
    expect(kinds(text)).toContain(kind);
  });

  it("passes what the rule leaves", () => {
    const shown = r.text(
      "box.internal 10.0.0.5 me@host.example.net github.com/someone/x proj-one Auth zone busyyaks_work Alex someone/tool",
    );
    expect(rule.leaks(shown, spec)).toEqual([]);
    expect(kinds("busyyaks · github.com/pubowner/busyyaks · app.rb · 127.0.0.1 · ci.example.com")).toEqual([]);
  });
});

describe("samples.js: the pictures shown for a card's attachments", () => {
  const module = {
    exports: {} as { samplePicture: (id: unknown) => { kind: string; svg: string }; KIND_NAMES: string[] },
  };
  runInNewContext(SAMPLES, { module });
  const { samplePicture, KIND_NAMES } = module.exports;

  it("draws shapes only: an SVG with no text, no font, no link and no outside reference", () => {
    for (let id = 0; id < 40; id++) {
      const { svg } = samplePicture(id);
      expect(svg).toMatch(/^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"[^>]*>.*<\/svg>$/s);
      expect(svg).not.toMatch(/<(text|tspan|foreignObject|image|use|a|style|script)\b|href|font|url\(/i);
      expect(svg).not.toMatch(/NaN|undefined/);
    }
  });

  it("is the same picture for the same id, and neighbouring ids get every kind", () => {
    expect(samplePicture(2498)).toEqual(samplePicture("2498"));
    const kinds = new Set(Array.from({ length: KIND_NAMES.length }, (_, i) => samplePicture(100 + i).kind));
    expect([...kinds].sort()).toEqual([...KIND_NAMES].sort());
    expect(samplePicture(7).svg).not.toBe(samplePicture(7 + KIND_NAMES.length).svg);
  });

  it("refuses an id that is not a plain attachment number", () => {
    for (const id of ["download", "", " ", null, undefined, "0x1F", "1e3", "-4", "2.5"])
      expect(() => samplePicture(id)).toThrow(/numeric attachment id/);
  });
});
