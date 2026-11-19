import { describe, expect, it } from "vitest";
import { notice, pollEvery, progress, rows, type Check, type UpdateStatus } from "./updates";

const A = "a".repeat(40);
const B = "b".repeat(40);
const C = "c".repeat(40);

const check = (over: Partial<Check> = {}): Check => ({
  remote: "origin",
  url: "git@example.test:me/busyyaks.git",
  channel: "tags",
  checked_at: "2026-11-18T10:00:00Z",
  head: { sha: A, branch: "main", describe: "v1.0.0-2-gaaaaaaa" },
  dirty: [],
  tag: {
    name: "v1.1.0",
    sha: B,
    version: "1.1.0",
    state: "available",
    behind: 3,
  },
  branch: { name: "main", sha: C, state: "available", behind: 9 },
  ignored_tags: [],
  available: true,
  ...over,
});

const status = (over: Partial<UpdateStatus> = {}): UpdateStatus => ({
  settings: {
    remote: "origin",
    branch: "main",
    tags: "v*",
    channel: "tags",
    check_minutes: 60,
  },
  check: check(),
  checking: false,
  check_error: null,
  running: false,
  last: null,
  ...over,
});

describe("notice", () => {
  it("names the tag on the tags channel, the branch + commits on the branch channel", () => {
    expect(notice(status())).toBe("v1.1.0 available");
    expect(notice(status({ check: check({ channel: "branch" }) }))).toBe("main +9");
  });
  it("is null with no check, or when the channel's target is not a fast-forward away", () => {
    expect(notice(undefined)).toBeNull();
    expect(notice(status({ check: null }))).toBeNull();
    expect(notice(status({ check: check({ available: false }) }))).toBeNull();
  });
});

describe("rows", () => {
  it("one per target; available + clean → Update on", () => {
    const [t, b] = rows(status());
    expect(t).toMatchObject({
      mode: "tags",
      name: "v1.1.0",
      detail: "available · 3 commits",
      blocked: null,
    });
    expect(b).toMatchObject({
      mode: "branch",
      label: "origin/main",
      detail: "available · 9 commits",
      blocked: null,
    });
  });
  it("says why Update is off: current, ahead, diverged, no tag, dirty, another branch, a running update", () => {
    const off = (over: Partial<UpdateStatus>) => rows(status(over)).map((r) => r.blocked);
    expect(
      off({
        check: check({
          tag: { state: "none" },
          branch: { name: "main", sha: A, state: "current" },
        }),
      }),
    ).toEqual(["no version tag", "current"]);
    expect(
      off({
        check: check({
          tag: { name: "v1", sha: B, state: "ahead" },
          branch: { sha: C, state: "diverged", behind: 2 },
        }),
      }),
    ).toEqual(["checkout is ahead", "diverged"]);
    expect(off({ check: check({ dirty: ["Gemfile"] }) })).toEqual(["1 tracked file changed", "1 tracked file changed"]);
    expect(
      off({
        check: check({ head: { sha: A, branch: "dev", describe: "" } }),
      })[0],
    ).toBe("checkout on dev, updates follow main");
    expect(off({ running: true })).toEqual(["an update is running", "an update is running"]);
  });
  it("a record left 'running' / 'interrupted' never holds the buttons: only the launcher's running (the lock) does", () => {
    expect(rows(status({ last: { state: "running", step: "build" } }))[0]!.blocked).toBeNull();
    expect(rows(status({ last: { state: "interrupted", step: "up", error: "x" } }))[0]!.blocked).toBeNull();
  });
  it("a detached checkout (a tag install) may update", () => {
    expect(
      rows(
        status({
          check: check({ head: { sha: A, branch: null, describe: "v1.0.0" } }),
        }),
      )[0]!.blocked,
    ).toBeNull();
  });
  it("no check → no rows", () => expect(rows(status({ check: null }))).toEqual([]));
});

describe("progress", () => {
  it("n / total from the record's step; done = total", () => {
    expect(progress(null)).toBeNull();
    expect(progress({ state: "running", step: "build" })).toEqual({
      step: "build",
      index: 2,
      total: 7,
      state: "running",
    });
    expect(progress({ state: "done", step: null })).toEqual({
      step: "done",
      index: 7,
      total: 7,
      state: "done",
    });
    expect(progress({ state: "failed", step: "up", error: "x" })!.index).toBe(4);
  });
});

describe("pollEvery", () => {
  it("3 s while running, checking or the web is down; 60 s otherwise", () => {
    expect(pollEvery(status(), false)).toBe(60000);
    expect(pollEvery(status({ running: true }), false)).toBe(3000);
    expect(pollEvery(status({ checking: true }), false)).toBe(3000);
    expect(pollEvery(status({ last: { state: "starting" } }), false)).toBe(3000);
    expect(pollEvery(status({ last: { state: "interrupted" } }), false)).toBe(60000);
    expect(pollEvery(status(), true)).toBe(3000);
    expect(pollEvery(undefined, false)).toBe(60000);
  });
});
