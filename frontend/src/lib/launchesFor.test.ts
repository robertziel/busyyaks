// The page's launches narrowed to one board: a type that follows the lead gets the lead's launcher of THAT
// board — the Launch bar then locks the type's menu to it; no lead there → no follow.
import { describe, expect, it } from "vitest";
import { launchesFor } from "../components/Launch";
import type { LaunchesData } from "../types";

const session = (s: string, type: string, project: string, launcher: string) => ({
  id: 1,
  session: s,
  socket: "default",
  project,
  type,
  launcher,
  agent: `claude-${s}`,
  launched_by: "op",
  launched: "2026-11-06T16:00:00+01:00",
  last_seen: null,
  ended: null,
  end_reason: null,
  live: true,
  cards: 0,
});
const t = (key: string, follows: string | null) => ({
  key,
  label: key,
  launchers: [
    { key: "fullclaude", label: "fullclaude" },
    { key: "localclaude", label: "localclaude" },
  ],
  model: null,
  takes: [],
  max: null,
  max_per_project: null,
  prompt: true,
  running: 0,
  running_here: 0,
  launcher_follows: follows,
});
const all: LaunchesData = {
  types: [t("lead", null), t("team", "lead")],
  concurrency: {
    max_sessions: null,
    running: 2,
    free: null,
    types: {},
    sessions: [
      session("demo_app_teamlead", "lead", "demo_app", "localclaude"),
      session("busyyaks_teamlead", "lead", "busyyaks", "fullclaude"),
    ],
  },
  sessions_error: null,
};

describe("launchesFor", () => {
  it("a follower gets its board's lead launcher", () => {
    const team = launchesFor(all, "demo_app").types.find((x) => x.key === "team")!;
    expect(team.follows).toEqual({ type: "lead", session: "demo_app_teamlead", launcher: "localclaude" });
    expect(launchesFor(all, "busyyaks").types.find((x) => x.key === "team")!.follows).toEqual({
      type: "lead",
      session: "busyyaks_teamlead",
      launcher: "fullclaude",
    });
  });
  it("no lead on the board, or a type that follows nobody → no follow", () => {
    expect(launchesFor(all, "other_app").types.find((x) => x.key === "team")!.follows).toBeNull();
    expect(launchesFor(all, "demo_app").types.find((x) => x.key === "lead")!.follows).toBeNull();
  });
});
