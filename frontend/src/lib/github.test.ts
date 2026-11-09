import { describe, expect, it } from "vitest";
import type { GithubFeedStatus, GithubStatus } from "../types";
import { eventWord, feedLine, parseWindow, repoSummary, statusLine } from "./github";

const base: GithubStatus = {
  ok: true,
  error: null,
  last_run_at: 1000,
  last_ok_at: 1000,
  running_since: null,
  calls: 9,
  not_modified: 40,
  rate_remaining: 4931,
  rate_limit: 5000,
  rate_reset: 5000,
  follows_since: 900,
  follows_partial: false,
};

describe("parseWindow", () => {
  it("defaults to the daily window", () => {
    expect(parseWindow("")).toEqual({ key: "24h", hours: 24 });
  });
  it("reads 7d / 30d", () => {
    expect(parseWindow("?window=7d")).toEqual({ key: "7d", hours: 168 });
    expect(parseWindow("?window=30d")).toEqual({ key: "30d", hours: 720 });
  });
  it("reports an unknown window instead of picking one", () => {
    expect(parseWindow("?window=1y")).toEqual({ error: 'unknown window "1y" — use 24h, 7d, 30d' });
  });
});

describe("statusLine", () => {
  it("ok: when, cost, rate left", () => {
    expect(statusLine(base, 1000 + 720)).toEqual({
      tone: "ok",
      parts: ["collected 12m ago", "9 calls · 40 × 304", "4,931/5,000 API left"],
    });
  });
  it("failed: the error and the age of the data shown", () => {
    const s = { ...base, ok: false, error: "GitHub rate limited", last_run_at: 4600, rate_remaining: 0 };
    expect(statusLine(s, 4600 + 60)).toEqual({
      tone: "bad",
      parts: ["collection failed 1m ago: GitHub rate limited", "showing data from 1h ago", "0/5,000 API left"],
    });
  });
  it("failed with no good run ever", () => {
    const s = { ...base, ok: false, error: "GitHub rejected GITHUB_TOKEN (401)", last_ok_at: null };
    expect(statusLine(s, 1060).parts[1]).toBe("no good collection yet");
  });
  it("never collected", () => {
    const s = {
      ...base,
      ok: false,
      error: "no GitHub collection has run yet",
      last_run_at: null,
      last_ok_at: null,
      running_since: 950,
    };
    expect(statusLine(s, 1010)).toEqual({ tone: "warn", parts: ["no GitHub collection has run yet", "running 1m"] });
  });
});

const feed: GithubFeedStatus = {
  ok: true,
  error: null,
  last_run_at: 1000,
  last_ok_at: 1000,
  calls: 3,
  not_modified: 0,
  added: 12,
  since: 100,
  partial: false,
  gap_at: null,
};

describe("feedLine", () => {
  it("ok: when and cost", () => {
    expect(feedLine(feed, 1120, 500)).toEqual({ tone: "ok", parts: ["feed read 2m ago", "3 calls · 0 × 304"] });
  });
  it("says how far back a partial window is complete", () => {
    const l = feedLine({ ...feed, partial: true, since: 800 }, 1120, 500);
    expect(l.parts[2]).toMatch(/^complete since \d{4}-\d\d-\d\d \d\d:\d\d \(GitHub keeps 300 events\)$/);
  });
  it("a gap warns", () => {
    expect(feedLine({ ...feed, gap_at: 900 }, 1120, 500).tone).toBe("warn");
  });
  it("failed: the error and the age of the events shown", () => {
    const l = feedLine(
      { ...feed, ok: false, error: "GitHub 502", last_run_at: 1100, last_ok_at: 1000 - 3600 },
      1120,
      500,
    );
    expect(l).toEqual({ tone: "bad", parts: ["feed read failed 20s ago: GitHub 502", "showing events read 1h ago"] });
  });
  it("never read", () => {
    expect(feedLine({ ...feed, last_run_at: null, error: "the feed has not been collected yet" }, 1120, 500)).toEqual({
      tone: "warn",
      parts: ["the feed has not been collected yet"],
    });
  });
});

describe("eventWord / repoSummary", () => {
  it("plural and singular GitHub words", () => {
    expect(eventWord("PullRequestEvent", 2)).toBe("2 PRs");
    expect(eventWord("IssueCommentEvent", 1)).toBe("1 comment");
    expect(eventWord("SponsorshipEvent", 3)).toBe("3 Sponsorship");
  });
  it("one line per repo, at most 3 actors named", () => {
    const r = {
      repo: "o/r",
      total: 5,
      last_at: 1,
      types: [
        { type: "PushEvent", n: 3, actors: ["a", "b"] },
        { type: "IssuesEvent", n: 2, actors: ["b", "c", "d"] },
      ],
    };
    expect(repoSummary(r)).toEqual({ types: "3 pushes · 2 issues", actors: "a, b, c +1" });
  });
});
