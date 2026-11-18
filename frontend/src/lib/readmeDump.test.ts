/// <reference types="node" />
// scripts/readme-images/dump.js (the README screenshot environment's dump, outside the bundle; run in node by
// scripts/readme-images/dump): busyyaks' repos renamed to the demo's names from the live enrolments, never a list in
// code, and the pictures a card keeps — its newest that pass the gate, every failing one named. Synthetic names only.
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

type Picture = { id: number; card_id: number };
type Dump = {
  repoMap: (
    enrolments: { slug: string; local_repo: string | null; public_repo: string | null }[],
    ownRepos: string[],
    ownSlug?: string,
  ) => { map: (s: unknown) => unknown; demo: string[]; owned: string[]; real: string[]; seams: string[] };
  choosePictures: (
    candidates: Picture[],
    readmeCard: number,
    want: number,
    kindsOf: (a: Picture) => string[],
  ) => { chosen: Picture[]; skipped: { card: number; picture: number; kinds: string[] }[] };
  DEMO_OWNER: string;
};
const dump = createRequire(import.meta.url)("../../../scripts/readme-images/dump.js") as Dump;

const ENROLMENTS = [
  {
    slug: "work",
    local_repo: "https://github.com/pubowner/tool_private.git",
    public_repo: "https://github.com/pubowner/tool.git",
  },
  {
    slug: "eng",
    local_repo: "git@github.com:pubowner/engine_private.git",
    public_repo: "https://github.com/pubowner/engine.git",
  },
  {
    slug: "other",
    local_repo: "https://github.com/someone/x_private.git",
    public_repo: "https://github.com/someone/x.git",
  },
];

describe("dump.js: busyyaks' repos in the demo's names", () => {
  const r = dump.repoMap(ENROLMENTS, ["pubowner/tool", "pubowner/engine"]);

  it("maps each public repo and its enrolled local repo, in URLs and bare, any case", () => {
    expect(r.demo.sort()).toEqual(
      [
        "dev-example/engine",
        "dev-example/engine_dev",
        "dev-example/tool",
        "dev-example/tool_dev",
        "engine_dev",
        "tool_dev",
      ].sort(),
    );
    expect(r.map("https://github.com/pubowner/tool_private/pull/7")).toBe(
      "https://github.com/dev-example/tool_dev/pull/7",
    );
    expect(r.map("merged PubOwner/Engine #3")).toBe("merged dev-example/engine #3");
    expect(r.map("pubowner/tool")).toBe("dev-example/tool");
    expect(r.map("the tool_private repo, not pubowner/tool_private_x")).toBe(
      "the tool_dev repo, not pubowner/tool_private_x",
    );
  });

  it("leaves a longer name and every other repo as they are", () => {
    expect(r.map("pubowner/tool_extra and someone/x_private")).toBe("pubowner/tool_extra and someone/x_private");
    expect(r.map("someone/tool_private")).toBe("someone/tool_private");
    expect(r.owned.sort()).toEqual([
      "dev-example/engine",
      "dev-example/engine_dev",
      "dev-example/tool",
      "dev-example/tool_dev",
    ]);
  });

  it("names each private repo's seam: the public name's last word + what the private name adds", () => {
    expect(r.seams.sort()).toEqual(["engineprivate", "toolprivate"]);
  });

  it("leaves busyyaks' own working slug to the rule (it renames that one to busyyaks)", () => {
    const own = dump.repoMap(ENROLMENTS, ["pubowner/tool", "pubowner/engine"], "tool_private");
    expect(own.map("started for tool_private")).toBe("started for tool_private");
    expect(own.map("https://github.com/pubowner/tool_private/pull/1")).toBe(
      "https://github.com/dev-example/tool_dev/pull/1",
    );
    expect(r.map(42)).toBe(42);
  });

  it("refuses a public repo no enrolled project has", () => {
    expect(() => dump.repoMap(ENROLMENTS, ["pubowner/missing"])).toThrow(/no enrolled project has pubowner\/missing/);
  });
});

describe("dump.js: the pictures a card keeps", () => {
  const pics = [
    { id: 9, card_id: 1 },
    { id: 8, card_id: 1 },
    { id: 7, card_id: 1 },
    { id: 6, card_id: 2 },
    { id: 5, card_id: 2 },
    { id: 4, card_id: 3 },
  ];
  const bad = new Set([9, 6, 4]);
  const kindsOf = (a: Picture) => (bad.has(a.id) ? ["project name"] : []);

  it("keeps each card's newest clean picture, the README card's newest `want`, and names every skip", () => {
    const { chosen, skipped } = dump.choosePictures(pics, 1, 2, kindsOf);
    expect(chosen.map((a) => a.id)).toEqual([8, 7, 5]);
    expect(skipped).toEqual([
      { card: 1, picture: 9, kinds: ["project name"] },
      { card: 2, picture: 6, kinds: ["project name"] },
      { card: 3, picture: 4, kinds: ["project name"] },
    ]);
  });

  it("reads no picture past the ones a card keeps", () => {
    const seen: number[] = [];
    dump.choosePictures(pics, 1, 1, (a) => (seen.push(a.id), kindsOf(a)));
    expect(seen).toEqual([9, 8, 6, 5, 4]);
  });
});

// the gate's core on a synthetic live spec: names, terms and owners renamed, every leak refused where it is
type Spec = Record<string, unknown>;
type Built = {
  board: Record<string, unknown[]> & { cards: Record<string, unknown>[]; activity: Record<string, unknown>[] };
  merged: { repo: string; title: string }[];
  commits: [string, string][];
  chosen: Picture[];
  skipped: { card: number; picture: number; kinds: string[] }[];
  found: string[];
};
const gate = createRequire(import.meta.url)("../../../scripts/readme-images/dump.js") as {
  buildDump: (input: Record<string, unknown>) => Built;
  findLeaks: (dump: Record<string, unknown>, spec: Spec, demoNames: string[]) => string[];
  pictureKinds: (text: string, spec: Spec) => string[];
  dropList: (text: string) => string[];
};
const rule = createRequire(import.meta.url)("../../../scripts/readme-images/rename.js") as {
  specFrom: (input: Record<string, unknown>) => Spec;
};
const SPEC = rule.specFrom({
  slugs: ["work", "proj_one"],
  groups: ["zone"],
  repos: [],
  own: "work",
  keep: [],
  ownRepos: ["pubowner/tool", "pubowner/engine"],
  terms: ["secretword"],
  people: ["Alex Sample", "Alex", "Sample"],
});
const card = (over: Record<string, unknown> = {}) => ({
  id: 1,
  project_slug: "work",
  column: "doing",
  title: "Tidy work",
  notes: "",
  labels: "[]",
  question_options: null,
  metadata: null,
  owner_session: "work_worker",
  ...over,
});
const RAW = (over: Record<string, unknown> = {}) => ({
  card: 1,
  exported_at: 1,
  enrolments: ENROLMENTS,
  columns: [{ id: 1, key: "doing", label: "In progress" }],
  transitions: [],
  labels: [],
  cards: [card()],
  activity: [],
  checklists: [],
  items: [],
  attachments: [],
  pr_states: [],
  ...over,
});
const build = (raw: Record<string, unknown>, ocr: Record<number, string> = {}) =>
  gate.buildDump({
    raw,
    todayMerged: [],
    commitsText: "",
    spec: SPEC,
    ownRepos: ["pubowner/tool", "pubowner/engine"],
    pictures: 2,
    ocrText: (a: Picture) => ocr[a.id] ?? "",
  });

describe("dump.js: buildDump renames before it gates", () => {
  it("renames names, terms, owners and repos in every text, drops the live session, and passes the gate", () => {
    const out = build(
      RAW({
        cards: [
          card({
            notes:
              "see proj_one in zone; a secretword; gist.github.com/pubowner/abc; " +
              "https://github.com/pubowner/tool_private/pull/3 by Alex",
            metadata: JSON.stringify({
              prs: [
                {
                  url: "https://github.com/pubowner/tool_private/pull/3",
                  repo: "pubowner/tool_private",
                  role: "local",
                },
              ],
            }),
          }),
        ],
        activity: [{ id: 5, card_id: 1, body: "pinged work_worker", author: "worker-work_worker" }],
      }),
    );
    expect(out.found).toEqual([]);
    const text = JSON.stringify(out.board);
    for (const word of ["proj_one", "zone", "secretword", "pubowner", "Alex", "work_worker"])
      expect(text).not.toContain(word);
    const [first] = out.board.cards;
    expect(first?.owner_session).toBeNull();
    expect(first?.project_slug).toBe("busyyaks");
    const meta = JSON.parse(String(first?.metadata)) as { prs: { repo: string }[] };
    expect(meta.prs[0]?.repo).toBe("dev-example/tool_dev");
  });

  it("skips a picture whose words name a real repo or its owner, keeps the next clean one", () => {
    const out = build(
      RAW({
        attachments: [
          { id: 30, card_id: 1, content_type: "image/png", filename: "a.png", bytes: "" },
          { id: 29, card_id: 1, content_type: "image/png", filename: "b.png", bytes: "" },
          { id: 28, card_id: 1, content_type: "image/png", filename: "c.png", bytes: "" },
          { id: 27, card_id: 1, content_type: "image/png", filename: "d.png", bytes: "" },
        ],
      }),
      { 30: "open pubowner/tool now", 29: "signed in as PubOwner", 28: "a clean board", 27: "proj_one" },
    );
    expect(out.chosen.map((a) => a.id)).toEqual([28]);
    expect(out.skipped.map((s) => [s.picture, s.kinds])).toEqual([
      [30, ["private term"]],
      [29, ["private term"]],
      [27, ["project name"]],
    ]);
  });

  it("skips a picture on the operator's drop list, whatever its words", () => {
    const out = gate.buildDump({
      raw: RAW({
        attachments: [
          { id: 40, card_id: 1, content_type: "image/png", filename: "a.png", bytes: "" },
          { id: 39, card_id: 1, content_type: "image/png", filename: "b.png", bytes: "" },
        ],
      }),
      todayMerged: [],
      commitsText: "",
      spec: SPEC,
      ownRepos: ["pubowner/tool", "pubowner/engine"],
      pictures: 2,
      ocrText: () => "a clean board",
      drop: ["40"],
    });
    expect(out.chosen.map((a) => a.id)).toEqual([39]);
    expect(out.skipped).toEqual([{ card: 1, picture: 40, kinds: ["on the drop list"] }]);
  });

  it("reads the drop list: one id per line, # comments, anything else refused", () => {
    expect(gate.dropList("# ruled out\n2014 # a struck row\n\n2578\n")).toEqual(["2014", "2578"]);
    expect(() => gate.dropList("2014, 2578")).toThrow(/not a picture id/);
  });

  it("takes a commit's subject as everything after its first tab, and refuses a line without its time", () => {
    const go = (commitsText: string) =>
      gate.buildDump({
        raw: RAW(),
        todayMerged: [],
        commitsText,
        spec: SPEC,
        ownRepos: ["pubowner/tool", "pubowner/engine"],
        pictures: 1,
        ocrText: () => "",
      });
    expect(go("10\tFix\tthe bug\n").commits).toEqual([["10", "Fix the bug"]]);
    expect(() => go("no time here\n")).toThrow(/without its time/);
  });
});

describe("dump.js: findLeaks names every leak where it is", () => {
  const demo = ["dev-example/tool", "dev-example/tool_dev"];
  const gateSpec = { ...SPEC, ownRepos: demo, terms: ["secretword", "pubowner"] };
  const clean = {
    board: {
      cards: [
        { id: 1, notes: "fine", metadata: JSON.stringify({ prs: [{ repo: "dev-example/tool_dev", url: "x" }] }) },
      ],
      activity: [{ id: 2, body: "fine" }],
      items: [{ id: 3, body: "fine" }],
      pr_states: [{ id: 4, repo: "dev-example/tool" }],
      attachments: [{ id: 5, file: "5.png" }],
    },
    merged: [{ repo: "dev-example/tool", title: "fine", url: "https://github.com/dev-example/tool/pull/1" }],
    commits: [["1", "fine"]],
  };

  it("passes a clean dump (a picture's own file name is never read)", () => {
    expect(gate.findLeaks(clean, gateSpec, demo)).toEqual([]);
  });

  it("refuses each table's leak by table, row and field", () => {
    const leaky = {
      board: {
        cards: [
          { id: 1, notes: "a secretword", metadata: JSON.stringify({ prs: [{ repo: "pubowner/tool", url: "x" }] }) },
        ],
        activity: [{ id: 2, body: "see proj_one" }],
        items: [{ id: 3, body: "signed by Alex" }],
        pr_states: [{ id: 4, repo: "someone/else" }],
      },
      merged: [{ repo: "dev-example/tool", title: "zone work", url: "u" }],
      commits: [["1", "secretword again"]],
    };
    const found = gate.findLeaks(leaky, gateSpec, demo);
    for (const where of [
      "private term (line 1 of the term list) in cards 1 notes",
      "a PR repo outside the demo's names in cards 1 metadata",
      "project name (project 1 of the dashboard) in activity 2 body",
      "operator's name (word 2) in items 3 body",
      "a repo outside the demo's names in pr_states 4 repo",
      "group name (group 1) in merged 0 title",
      "in commit 1",
    ])
      expect(found.some((f) => f.includes(where))).toBe(true);
  });
});

describe("dump.js: a picture's words, as tesseract reads them", () => {
  const gateSpec = {
    ...SPEC,
    ownRepos: ["dev-example/tool"],
    terms: ["secretword", "pubowner/tool_private"],
    seams: ["toolprivate"],
  };

  it("finds a name the page wrapped at its _ (one piece per line)", () => {
    expect(gate.pictureKinds("#91 pubowner/tool_\nprivate merged", gateSpec)).toContain("private term");
    expect(gate.pictureKinds("see proj_\n one here", gateSpec)).toContain("project name");
  });

  it("finds a private repo name read with spaces for its _ and split across two columns", () => {
    expect(gate.pictureKinds("#91 pubowner/tool_ open x #91 pubowner/tool_\nprivate merged", gateSpec)).toContain(
      "private term",
    );
    expect(gate.pictureKinds("pubowner tool private", gateSpec)).toContain("private term");
  });

  it("finds a private repo name whose words two columns interleaved, by its seam", () => {
    const rail = "#91 pubowner_ open behind x | junk\nother_tool_ other_tool_\ntool private tool private";
    expect(gate.pictureKinds(rail, gateSpec)).toContain("private repo name");
  });

  it("finds a private term split by spaces, and passes clean words", () => {
    expect(gate.pictureKinds("a secret word here", gateSpec)).toEqual(["private term"]);
    expect(gate.pictureKinds("a clean board · 5 to review", gateSpec)).toEqual([]);
  });
});
