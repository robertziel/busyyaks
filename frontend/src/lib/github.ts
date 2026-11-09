// The /github page's pure logic: which window the URL asks for, and the collector status line.
import type { GithubFeedRepo, GithubFeedStatus, GithubStatus } from "../types";
import { ago, at } from "./format";

export const WINDOWS = [
  { key: "24h", hours: 24 },
  { key: "7d", hours: 168 },
  { key: "30d", hours: 720 },
] as const;
export type WindowKey = (typeof WINDOWS)[number]["key"];

// ?window=24h|7d|30d; none → 24h (the daily report's window). An unknown value is reported, never mapped to another.
export function parseWindow(search: string): { key: WindowKey; hours: number } | { error: string } {
  const v = new URLSearchParams(search).get("window");
  if (v == null || v === "") return WINDOWS[0];
  const w = WINDOWS.find((x) => x.key === v);
  return w ?? { error: `unknown window "${v}" — use ${WINDOWS.map((x) => x.key).join(", ")}` };
}

const n = (x: number) => x.toLocaleString("en-US");

export type StatusLine = { tone: "ok" | "bad" | "warn"; parts: string[] };

// One line of facts about the collection the page shows: when, how it went, what it cost, what is left.
export function statusLine(s: GithubStatus, now: number): StatusLine {
  const rate =
    s.rate_remaining != null && s.rate_limit != null ? `${n(s.rate_remaining)}/${n(s.rate_limit)} API left` : null;
  const cost = s.calls != null ? `${s.calls} calls · ${s.not_modified ?? 0} × 304` : null;
  if (s.last_run_at == null) {
    const parts = [s.error ?? "no collection yet"];
    if (s.running_since != null) parts.push(`running ${ago(s.running_since, now)}`);
    return { tone: "warn", parts };
  }
  if (!s.ok) {
    const parts = [`collection failed ${ago(s.last_run_at, now)} ago: ${s.error ?? "unknown error"}`];
    parts.push(s.last_ok_at != null ? `showing data from ${ago(s.last_ok_at, now)} ago` : "no good collection yet");
    if (rate) parts.push(rate);
    return { tone: "bad", parts };
  }
  const parts = [`collected ${ago(s.last_run_at, now)} ago`];
  if (cost) parts.push(cost);
  if (rate) parts.push(rate);
  return { tone: "ok", parts };
}

// The feed's own line: when it was read, what it cost, how far back it is complete, a gap, or why it failed.
export function feedLine(s: GithubFeedStatus, now: number, windowFrom: number): StatusLine {
  if (s.last_run_at == null) return { tone: "warn", parts: [s.error ?? "feed not collected yet"] };
  const parts: string[] = [];
  let tone: StatusLine["tone"] = "ok";
  if (!s.ok) {
    tone = "bad";
    parts.push(`feed read failed ${ago(s.last_run_at, now)} ago: ${s.error ?? "unknown error"}`);
    parts.push(s.last_ok_at != null ? `showing events read ${ago(s.last_ok_at, now)} ago` : "no good read yet");
  } else {
    parts.push(`feed read ${ago(s.last_run_at, now)} ago`);
    if (s.calls != null) parts.push(`${s.calls} calls · ${s.not_modified ?? 0} × 304`);
  }
  if (s.partial && s.since != null && s.since > windowFrom)
    parts.push(`complete since ${at(s.since)} (GitHub keeps 300 events)`);
  if (s.gap_at != null) {
    parts.push(`gap at ${at(s.gap_at)}: >300 events between reads`);
    if (tone === "ok") tone = "warn";
  }
  return { tone, parts };
}

// "PullRequestReviewEvent" → "review"; counts read as GitHub words
const EVENT_WORD: Record<string, [string, string]> = {
  PushEvent: ["push", "pushes"],
  IssueCommentEvent: ["comment", "comments"],
  IssuesEvent: ["issue", "issues"],
  PullRequestEvent: ["PR", "PRs"],
  PullRequestReviewEvent: ["review", "reviews"],
  PullRequestReviewCommentEvent: ["review comment", "review comments"],
  WatchEvent: ["star", "stars"],
  ForkEvent: ["fork", "forks"],
  ReleaseEvent: ["release", "releases"],
  CreateEvent: ["create", "creates"],
  DeleteEvent: ["delete", "deletes"],
  PublicEvent: ["made public", "made public"],
  MemberEvent: ["member", "members"],
  GollumEvent: ["wiki edit", "wiki edits"],
  CommitCommentEvent: ["commit comment", "commit comments"],
};
export function eventWord(type: string, n: number): string {
  const bare = type.replace(/Event$/, "");
  const w = EVENT_WORD[type] ?? [bare, bare];
  return `${n} ${n === 1 ? w[0] : w[1]}`;
}

// one line per repo: "12 comments · 3 PRs", by "alice, bob" — the most active repos first (the server's order)
export function repoSummary(r: GithubFeedRepo): { types: string; actors: string } {
  const actors = [...new Set(r.types.flatMap((t) => t.actors))];
  return {
    types: r.types.map((t) => eventWord(t.type, t.n)).join(" · "),
    actors: actors.length > 3 ? `${actors.slice(0, 3).join(", ")} +${actors.length - 3}` : actors.join(", "),
  };
}
