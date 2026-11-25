import { describe, expect, it } from "vitest";
import {
  attention,
  commitsLabel,
  folded,
  leaf,
  localDay,
  repoUnit,
  reportBlock,
  weekBars,
  weekLabel,
  yearFacts,
} from "./today";
import type { Project, TreeNode } from "../types";

const proj = (slug: string, dirty: number, unpushed: number | null): Project => ({
  slug,
  path: `/projects/${slug}`,
  remote: null,
  icon: null,
  repo_url: null,
  branch: "main",
  detached_sha: null,
  head_label: "main",
  own: true,
  last_commit_at: 1000,
  commits_window: 1,
  mine_window: 0,
  dirty,
  unpushed,
  scanned_at: 1,
  present: true,
  sessions: [],
});
const repo = (slug: string, dirty: number, unpushed: number | null): TreeNode => ({
  type: "repo",
  name: leaf(slug),
  project: proj(slug, dirty, unpushed),
});
const stats = { repos: 9, active7: 4, commits_today: 5, dirty: 5, unpushed: 2, prs_today: null };

describe("attention", () => {
  const tree: TreeNode[] = [
    repo("a", 2, 0),
    {
      type: "folder",
      name: "g",
      path: "g",
      repos: 2,
      last_commit_at: 1000,
      commits_window: 2,
      mine_window: 0,
      dirty: 9,
      unpushed: 3,
      live: 0,
      children: [repo("g/b", 9, null), repo("g/c", 0, 3)],
    },
    repo("d", 2, 1),
  ];
  const a = attention(tree, stats);
  it("lists the active repos with uncommitted files, most first, folders walked, ties by name", () => {
    expect(a.dirty.repos).toEqual([
      { slug: "g/b", n: 9 },
      { slug: "a", n: 2 },
      { slug: "d", n: 2 },
    ]);
  });
  it("keeps the server's count and says how many of it the active tree does not hold", () => {
    expect(a.dirty.total).toBe(5);
    expect(a.dirty.rest).toBe(2);
    expect(a.unpushed.rest).toBe(0);
  });
  it("a repo with no upstream (unpushed unknown) is not listed as unpushed", () => {
    expect(a.unpushed.repos).toEqual([
      { slug: "g/c", n: 3 },
      { slug: "d", n: 1 },
    ]);
  });
  it("nothing pending: empty lists, the counts as given", () => {
    const none = attention([repo("a", 0, 0)], { ...stats, dirty: 0, unpushed: 0 });
    expect(none.dirty).toEqual({ total: 0, repos: [], rest: 0 });
    expect(none.unpushed).toEqual({ total: 0, repos: [], rest: 0 });
  });
});

describe("folded", () => {
  it("shows the first `fold` and counts the rest; open or short lists show all", () => {
    expect(folded([1, 2, 3, 4], 3, false)).toEqual({ shown: [1, 2, 3], hidden: 1 });
    expect(folded([1, 2, 3, 4], 3, true)).toEqual({ shown: [1, 2, 3, 4], hidden: 0 });
    expect(folded([1, 2, 3], 3, false)).toEqual({ shown: [1, 2, 3], hidden: 0 });
  });
});

describe("leaf", () => {
  it("is the slug's last path segment", () => {
    expect(leaf("group/sub/repo")).toBe("repo");
    expect(leaf("repo")).toBe("repo");
  });
});

describe("commitsLabel", () => {
  const days = [
    { day: "2026-11-07", commits: 5, mine: 3, repos: 1, prs: null },
    { day: "2026-11-06", commits: 8, mine: 6, repos: 3, prs: 2 },
  ];
  it("the day's commits, mine and repos; `latest N` when the list is shorter than the day", () => {
    expect(commitsLabel(stats, days, "2026-11-07", 5)).toEqual(["5 commits", "3 mine", "1 repo"]);
    expect(commitsLabel({ ...stats, commits_today: 262 }, days, "2026-11-07", 60)).toEqual([
      "262 commits",
      "3 mine",
      "1 repo",
      "latest 60",
    ]);
  });
  it("no row for today: mine and repos are not known — left out, never 0", () => {
    expect(commitsLabel({ ...stats, commits_today: 1 }, days, "2026-11-08", 1)).toEqual(["1 commit"]);
    expect(commitsLabel({ ...stats, commits_today: 0 }, [], "2026-11-08", 0)).toEqual(["0 commits"]);
  });
});

describe("week", () => {
  const rows = [
    { project_slug: "a", commits: 200, mine: 50 },
    { project_slug: "b", commits: 50, mine: 50 },
    { project_slug: "c", commits: 0, mine: 0 },
  ];
  it("a bar is the repo's share of the busiest, its solid part my share of the repo", () => {
    expect(weekBars(rows)).toEqual([
      { slug: "a", commits: 200, mine: 50, pct: 100, minePct: 25 },
      { slug: "b", commits: 50, mine: 50, pct: 25, minePct: 100 },
      { slug: "c", commits: 0, mine: 0, pct: 0, minePct: 0 },
    ]);
    expect(weekBars([{ project_slug: "c", commits: 0, mine: 0 }])[0]!.pct).toBe(0);
    expect(weekBars([])).toEqual([]);
  });
  it("the label says when the list is cut", () => {
    expect(weekLabel(rows, 21)).toBe("top 3 of 21 repos");
    expect(weekLabel(rows, 3)).toBe("3 repos");
    expect(weekLabel(rows.slice(0, 1), 1)).toBe("1 repo");
  });
});

describe("yearFacts", () => {
  const today = new Date(2026, 10, 17);
  it("counts active days, the streak ending today and the busiest day (the newest on a tie)", () => {
    const f = yearFacts(
      { "2026-11-17": 2, "2026-11-16": 7, "2026-11-15": 7, "2026-11-13": 1, "2025-11-18": 3, "2025-11-17": 99 },
      today,
    );
    expect(f.active).toBe(5); // 2025-11-17 is 365 days back: outside the 365 ending today
    expect(f.streak).toBe(3);
    expect(f.best).toEqual({ day: "2026-11-16", n: 7 });
  });
  it("today without commits yet: the streak that ended yesterday still stands", () => {
    expect(yearFacts({ "2026-11-16": 1, "2026-11-15": 4 }, today).streak).toBe(2);
    expect(yearFacts({ "2026-11-15": 4 }, today).streak).toBe(0);
  });
  it("an empty year: 0 active days, no best day", () => {
    expect(yearFacts({}, today)).toEqual({ active: 0, streak: 0, best: null });
  });
});

describe("repoUnit", () => {
  it("a pending line's total counts repos, never files or commits", () => {
    expect(repoUnit(1)).toBe("repo");
    expect(repoUnit(0)).toBe("repos");
    expect(repoUnit(69)).toBe("repos");
  });
});

describe("localDay", () => {
  it("is the local calendar day: past midnight the year's facts count the new day", () => {
    expect(localDay(new Date(2026, 10, 17, 23, 59))).toBe("2026-11-17");
    expect(localDay(new Date(2026, 10, 18, 0, 0))).toBe("2026-11-18");
    const counts = { "2026-11-17": 3 };
    expect(yearFacts(counts, new Date(2026, 10, 17)).streak).toBe(1);
    expect(yearFacts(counts, new Date(2026, 10, 18)).streak).toBe(1); // today (18th) empty: yesterday's stands
    expect(yearFacts(counts, new Date(2026, 10, 19)).streak).toBe(0);
  });
});

describe("folded toggle", () => {
  it("open shows every item, closed again folds back to `fold`", () => {
    const items = [1, 2, 3, 4, 5];
    expect(folded(items, 2, false)).toEqual({ shown: [1, 2], hidden: 3 });
    expect(folded(items, 2, true)).toEqual({ shown: items, hidden: 0 });
    expect(folded(items, 2, false)).toEqual({ shown: [1, 2], hidden: 3 });
    expect(folded([], 2, false)).toEqual({ shown: [], hidden: 0 });
  });
});

describe("reportBlock", () => {
  it("today's reports: the count in the head", () => {
    expect(reportBlock("2026-11-17", ["a", "b"], "z")).toEqual({ parts: ["2026-11-17", "2 today"], shown: ["a", "b"] });
  });
  it("none today: the latest one, marked latest", () => {
    expect(reportBlock("2026-11-17", [], "z")).toEqual({ parts: ["2026-11-17", "0 today", "latest"], shown: ["z"] });
  });
  it("none at all: the head says 0 today, the body repeats nothing", () => {
    expect(reportBlock<string>("2026-11-17", [], null)).toEqual({ parts: ["2026-11-17", "0 today"], shown: [] });
  });
});
