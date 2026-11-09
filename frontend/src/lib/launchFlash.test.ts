// The launch flash: a repo not trusted from outside it keeps Claude Code's folder-trust prompt on screen (bin/launcher
// answers it only for launch.trusted_paths and repos it made itself), and the flash says so — never a clean start.
import { describe, expect, it } from "vitest";
import { launchFlash } from "../components/Launch";
import type { LaunchResult } from "../types";

const result = (trust: "accepted" | "failed" | "left" | undefined, trust_reason?: string) =>
  ({
    session: "g_r_teamlead",
    type: "lead",
    launcher: "claude",
    agent: "claude-g_r_teamlead",
    adopted: [],
    result: { remote_control: "on", remote_control_name: "g_r_teamlead", trust, trust_reason },
  }) as unknown as LaunchResult;

describe("launchFlash", () => {
  it("a trusted owned repo is a clean start", () => {
    const f = launchFlash(result("accepted"));
    expect(f.ok).toBe(true);
    expect(f.text).toContain("folder trusted");
  });

  it("a prompt left for the operator is not ok and names why", () => {
    const why = "/p/x is not in config/busyyaks.yml launch.trusted_paths and was not made by the launcher's git init";
    const f = launchFlash(result("left", why));
    expect(f.ok).toBe(false);
    expect(f.text).toContain(`TRUST PROMPT LEFT FOR YOU: ${why}`);
  });
});
