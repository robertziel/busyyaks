import { describe, expect, it } from "vitest";
import { chipCounts, repos, visible } from "./tree";
import type { Project, TreeNode } from "../types";

const proj = (slug: string, extra: Partial<Project> = {}): Project => ({
  slug,
  path: `/projects/${slug}`,
  remote: null,
  icon: null,
  repo_url: null,
  branch: "main",
  own: true,
  last_commit_at: 1000,
  commits_window: 1,
  mine_window: 0,
  dirty: 0,
  unpushed: null,
  scanned_at: 1,
  present: true,
  sessions: [],
  ...extra,
});

const tree: TreeNode[] = [
  {
    type: "folder",
    name: "g",
    path: "g",
    repos: 2,
    last_commit_at: 1000,
    commits_window: 2,
    mine_window: 0,
    dirty: 2,
    unpushed: null,
    live: 0,
    children: [
      { type: "repo", name: "x", project: proj("g/x", { dirty: 2 }) },
      {
        type: "repo",
        name: "y",
        project: proj("g/y", {
          own: false,
          sessions: [{ name: "s", created: 1, attached: false, terminal_url: "t", claude_url: null, ssh_attach: "s" }],
        }),
      },
    ],
  },
  { type: "repo", name: "a", project: proj("a", { last_commit_at: 10 }) },
];

describe("tree", () => {
  it("shows only top level when folders are closed, children when open", () => {
    const closed = visible(tree, { text: "", chips: new Set() }, {}, 500);
    expect(closed.rows.map((r) => (r.kind === "folder" ? r.node.path : r.project.slug))).toEqual(["g", "a"]);
    expect(closed.total).toBe(3);
    const open = visible(tree, { text: "", chips: new Set() }, { g: true }, 500);
    expect(open.rows).toHaveLength(4);
    expect(open.expanded.has("g")).toBe(true);
  });

  it("filters repos and keeps the folders on their path, expanded", () => {
    const v = visible(tree, { text: "y", chips: new Set() }, {}, 500);
    expect(v.rows.map((r) => (r.kind === "folder" ? r.node.path : r.project.slug))).toEqual(["g", "g/y"]);
    expect(v.shown).toBe(1);
    const chips = visible(tree, { text: "", chips: new Set(["dirty"]) }, {}, 500);
    expect(chips.rows.map((r) => (r.kind === "folder" ? r.node.path : r.project.slug))).toEqual(["g", "g/x"]);
  });

  it("counts chips", () => {
    expect(chipCounts(repos(tree), 500)).toEqual({ own: 2, upstream: 1, active: 2, dirty: 1, unpushed: 0, live: 1 });
  });
});
