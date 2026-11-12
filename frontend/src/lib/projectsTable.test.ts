// The projects tree table's markup: no Kind column (an "upstream" tag beside the name, nothing for your own repos),
// the short "7d" header, and every number cell labelled for the phone layout (its header is hidden there).
import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { ProjectsTable } from "../components/ProjectsTable";
import type { Project, TreeNode } from "../types";
import { visible } from "./tree";

const proj = (slug: string, extra: Partial<Project> = {}): Project => ({
  slug,
  path: `/projects/${slug}`,
  remote: null,
  icon: null,
  repo_url: null,
  branch: "main",
  own: true,
  last_commit_at: 1000,
  commits_window: 3,
  mine_window: 2,
  dirty: 0,
  unpushed: null,
  scanned_at: 1,
  present: true,
  sessions: [],
  ...extra,
});

const tree: TreeNode[] = [
  { type: "repo", name: "mine-repo", project: proj("mine-repo") },
  { type: "repo", name: "their-repo", project: proj("their-repo", { own: false, dirty: 4 }) },
];

const html = () => {
  const v = visible(tree, { text: "", chips: new Set() }, {}, 500);
  return renderToStaticMarkup(
    createElement(
      MemoryRouter,
      null,
      createElement(ProjectsTable, {
        rows: v.rows,
        expanded: v.expanded,
        active: false,
        shown: v.shown,
        onToggle: () => undefined,
        launches: { types: [], concurrency: null, sessions_error: null },
        launcherError: null,
      }),
    ),
  );
};

describe("ProjectsTable", () => {
  it("tags only upstream repos, beside the name, with no Kind column", () => {
    const h = html();
    expect(h).not.toMatch(/>kind</);
    expect(h).not.toContain('class="tag own"');
    expect(h.match(/class="tag up"/g)).toHaveLength(1);
    expect(h).toMatch(/their-repo<\/span><\/a><span class="tag up"[^>]*>upstream<\/span>/);
  });

  it("heads the commits column 7d and labels every number for the phone", () => {
    const h = html();
    expect(h).toMatch(/<th role="columnheader" class="n" title="commits in the last 7 days">7d<\/th>/);
    for (const l of ["7d", "mine", "dirty", "unpushed"]) expect(h).toContain(`data-label="${l}"`);
    expect(h).toContain('<td role="cell" class="n mine" data-label="mine">2</td>');
    expect(h).toContain('<td role="cell" class="n warn" data-label="dirty"><span class="pip">4</span></td>');
  });

  it("marks an unknown number unknown, not zero: — stays, only zeros are hidden on a phone", () => {
    const h = html();
    expect(h).toContain('<td role="cell" class="n unknown" data-label="unpushed" title="unknown">—</td>');
    expect(h).toContain('<td role="cell" class="n zero" data-label="dirty">0</td>');
  });

  it("keeps table roles on every element, so the card layout stays a table to screen readers", () => {
    const h = html();
    expect(h).toContain('<table class="data tree" role="table">');
    expect(h).toContain('<thead role="rowgroup">');
    expect(h).toContain('<tbody role="rowgroup">');
    expect(h.match(/<tr[ >](?!role="row")/g)).toBeNull();
    expect(h.match(/<td[ >](?!role="cell")/g)).toBeNull();
    expect(h.match(/<th[ >](?!role="columnheader")/g)).toBeNull();
  });
});

// The layout rules the markup above relies on (vitest has no layout engine, so the CSS itself is checked).
const CSS = readFileSync(new URL("../styles/projects.css", import.meta.url), "utf8");
const block = (head: string) => {
  const i = CSS.indexOf(head);
  expect(i, head).toBeGreaterThan(-1);
  let depth = 0;
  for (let j = CSS.indexOf("{", i); j < CSS.length; j++) {
    if (CSS[j] === "{") depth++;
    else if (CSS[j] === "}" && --depth === 0) return CSS.slice(i, j + 1);
  }
  throw new Error(`unclosed ${head}`);
};

describe("projects.css", () => {
  const phone = block("@media (max-width: 900px) {");

  it("on a phone hides zeros, never an unknown", () => {
    expect(phone).toMatch(/table\.tree tr td\.zero,/);
    expect(phone).not.toMatch(/td\.unknown/);
  });

  it("on a phone hides the header visually only (not display: none)", () => {
    const thead = phone.slice(phone.indexOf("table.tree thead {"));
    expect(thead.slice(0, thead.indexOf("}"))).toMatch(/clip-path: inset\(50%\)/);
    expect(phone).not.toMatch(/thead \{\s*display: none/);
  });

  it("hides the host-wide session cap on rows, keeps a row's held cap and launch error", () => {
    expect(CSS).toContain("table.tree .ak-launchbar > .ak-cap[title]:not([data-held]) {");
    expect(CSS).not.toMatch(/\.ak-cap:not\(\.bad\)/);
  });

  it("drops mine at a 900 px table and branch at 1000 px, only above the phone layout", () => {
    const wide = block("@media (min-width: 901px) {");
    expect(wide).toMatch(/@container tree \(max-width: 1000px\) \{\s*table\.tree \.branch \{\s*display: none/);
    expect(wide).toMatch(/@container tree \(max-width: 900px\) \{\s*table\.tree \.mine \{\s*display: none/);
  });
});
