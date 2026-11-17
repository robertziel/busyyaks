// The fold toggles of the Today page's pending lines and commit log render folded, with a toggle whose
// name starts with its visible text and whose aria-expanded says the state (the open state is lib/today's `folded`).
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { CommitLog, PendingLine } from "./TodayParts";
import type { Commit } from "../types";

const render = (el: ReturnType<typeof createElement>) => renderToStaticMarkup(createElement(MemoryRouter, null, el));

const commit = (i: number): Commit => ({
  sha: `${i}`.padStart(40, "a"),
  subject: `subject ${i}`,
  author: "Someone",
  email: "someone",
  committed_at: 1000 - i,
  mine: true,
  project_slug: "group/repo",
  url: null,
});

describe("CommitLog fold", () => {
  it("past `fold`: the first rows and a closed toggle naming how many it hides", () => {
    const html = render(createElement(CommitLog, { commits: [1, 2, 3, 4, 5].map(commit), fold: 2 }));
    expect(html.match(/<li /g)?.length).toBe(2);
    expect(html).toContain('aria-expanded="false"');
    expect(html).toContain("Show 3 more");
  });
  it("within `fold`: every row, no toggle", () => {
    const html = render(createElement(CommitLog, { commits: [1, 2].map(commit), fold: 2 }));
    expect(html.match(/<li /g)?.length).toBe(2);
    expect(html).not.toContain("aria-expanded");
  });
  it("no commits: nothing (the section head says 0 commits)", () => {
    expect(render(createElement(CommitLog, { commits: [], fold: 2 }))).toBe("");
  });
});

describe("PendingLine fold", () => {
  const list = {
    total: 7,
    repos: [
      { slug: "a/one", n: 9 },
      { slug: "two", n: 4 },
      { slug: "three", n: 1 },
    ],
    rest: 4,
  };
  it("the total in repos, the first chips, a +N toggle whose name starts with its text, the rest linked", () => {
    const html = render(createElement(PendingLine, { label: "uncommitted", unit: "files", list, fold: 2 }));
    expect(html).toContain("7</b> repos");
    expect(html.match(/class="td-chip"/g)?.length).toBe(2);
    expect(html).toContain('aria-label="+1 more repos"');
    expect(html).toContain('aria-expanded="false"');
    expect(html).toContain("+4 not active 7d");
  });
  it("one repo: the unit is singular", () => {
    const one = { total: 1, repos: [{ slug: "x", n: 2 }], rest: 0 };
    const html = render(createElement(PendingLine, { label: "unpushed", unit: "commits", list: one, fold: 2 }));
    expect(html).toContain("1</b> repo<");
    expect(html).not.toContain("aria-expanded");
  });
});
