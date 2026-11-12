// the hello screen's launcher rows → the agent settings document it saves.
import { describe, expect, it } from "vitest";
import type { AgentDoc, AgentType, Invocation } from "./agentSettings";
import {
  agentPrompt,
  applyRows,
  typeChanges,
  defaultFrom,
  rowsError,
  rowsFrom,
  setupPending,
  type SetupData,
} from "./hello";

const claude: Invocation = { kind: "claude_code", command: "claude", args: [], via_shell: false };
const local: Invocation = { kind: "claude_code", command: "localclaude", args: [], via_shell: true };
const hermes: Invocation = { kind: "hermes", command: "hermes", args: ["chat"], via_shell: false };
const commands = [claude, local, hermes];

const type = (key: string, over: Partial<AgentType> = {}): AgentType => ({
  key,
  label: key,
  launchers: ["claude"],
  model: null,
  prompt: "p",
  agent_name: "a-{session}",
  session_name: "{slug}_" + key,
  takes: [],
  max: 0,
  max_per_project: 0,
  ...over,
});
const doc = (): AgentDoc => ({
  launchers: [
    { key: "claude", label: "claude", ...claude },
    { key: "old", label: "old", kind: "claude_code", command: "gone", args: [], via_shell: false },
  ],
  agent_types: [
    type("lead", { launchers: ["claude", "old"], model: { claude: "opus", old: null }, spawn_launcher: "claude" }),
    type("worker", { launcher_follows: "lead" }),
  ],
});

describe("setupPending", () => {
  it("only a pending shell not finished in this tab", () => {
    expect(setupPending("pending", false)).toBe(true);
    expect(setupPending("pending", true)).toBe(false);
    expect(setupPending("done", false)).toBe(false);
    expect(setupPending(null, false)).toBe(false);
  });
});

describe("rowsFrom", () => {
  it("existing launchers first (one on no allowlist entry cannot be used), then each unused command", () => {
    expect(rowsFrom(doc(), commands)).toEqual([
      { key: "claude", label: "claude", at: 0, use: true, existing: true },
      { key: "old", label: "old", at: -1, use: false, existing: true },
      { key: "localclaude", label: "localclaude", at: 1, use: false, existing: false },
      { key: "hermes", label: "hermes", at: 2, use: false, existing: false },
    ]);
  });

  it("a new row's key never repeats an existing one", () => {
    const d = doc();
    d.launchers[1] = { key: "hermes", label: "h", ...claude };
    const keys = rowsFrom(d, commands).map((r) => r.key);
    expect(new Set(keys).size).toBe(keys.length);
    expect(keys).toContain("hermes_2");
  });
});

describe("defaultFrom", () => {
  it("the lead's spawn launcher while it is in use, else the first in use", () => {
    const rows = rowsFrom(doc(), commands);
    expect(defaultFrom(doc(), rows)).toBe("claude");
    const off = rows.map((r) =>
      r.key === "claude" ? { ...r, use: false } : r.key === "hermes" ? { ...r, use: true } : r,
    );
    expect(defaultFrom(doc(), off)).toBe("hermes");
    expect(
      defaultFrom(
        doc(),
        rows.map((r) => ({ ...r, use: false })),
      ),
    ).toBe("");
  });
});

describe("rowsError", () => {
  const rows = rowsFrom(doc(), commands);
  it("names what blocks a save", () => {
    expect(rowsError(rows, "claude")).toBeNull();
    expect(
      rowsError(
        rows.map((r) => ({ ...r, use: false })),
        "claude",
      ),
    ).toBe("pick at least one command");
    expect(rowsError(rows, "hermes")).toBe("pick the default launcher");
    const dup = rows.map((r) => (r.key === "hermes" ? { ...r, use: true, key: "claude" } : r));
    expect(rowsError(dup, "claude")).toBe("two launchers share a key");
    const bad = rows.map((r) => (r.key === "hermes" ? { ...r, use: true, key: "9x" } : r));
    expect(rowsError(bad, "claude")).toMatch(/^a key starts with a-z/);
    const nolabel = rows.map((r) => (r.key === "hermes" ? { ...r, use: true, label: " " } : r));
    expect(rowsError(nolabel, "claude")).toBe("every launcher needs a label");
  });
});

describe("applyRows", () => {
  it("drops the launcher on no allowlist entry, adds the picked commands, the default first and spawned", () => {
    const rows = rowsFrom(doc(), commands).map((r) => (r.key === "hermes" ? { ...r, use: true, label: "Hermes" } : r));
    const out = applyRows(doc(), commands, rows, "hermes");
    expect(out.launchers).toEqual([
      { key: "claude", label: "claude", ...claude },
      { key: "hermes", label: "Hermes", ...hermes },
    ]);
    const lead = out.agent_types[0]!;
    expect(lead.launchers).toEqual(["hermes", "claude"]);
    expect(lead.spawn_launcher).toBe("hermes");
    expect(lead.model).toEqual({ hermes: null, claude: "opus" });
    expect(lead.prompt).toBe("p");
    const worker = out.agent_types[1]!;
    expect(worker.launchers).toEqual(["hermes", "claude"]);
    expect(worker.launcher_follows).toBe("lead");
    expect(worker.model).toBeNull();
  });

  it("a model map left with no model is null; one model for all is kept", () => {
    const d = doc();
    d.agent_types[0]!.model = { claude: null, old: "x" };
    d.agent_types[1]!.model = "sonnet";
    const out = applyRows(d, commands, rowsFrom(d, commands), "claude");
    expect(out.agent_types[0]!.model).toBeNull();
    expect(out.agent_types[1]!.model).toBe("sonnet");
    expect(out.agent_types[0]!.launchers).toEqual(["claude"]);
  });

  it("does not change the document it was given", () => {
    const d = doc();
    const before = JSON.stringify(d);
    applyRows(d, commands, rowsFrom(d, commands), "claude");
    expect(JSON.stringify(d)).toBe(before);
  });
});

describe("agentPrompt", () => {
  it("names the host dir, the repos found and the allowed commands", () => {
    const p: SetupData["projects"] = {
      host_root: "/srv/code",
      mount: "/projects",
      roots: [],
      search_depth: 2,
      repos: 3,
      sample: [],
    };
    const text = agentPrompt(p, [claude, hermes], "https://dash.example");
    expect(text).toContain("the dashboard at https://dash.example");
    expect(text).toContain("PROJECTS_ROOT is /srv/code (3 repos found)");
    expect(text).toContain("launch.commands allows claude, hermes chat.");
  });
});

describe("typeChanges", () => {
  it("lists each type whose launchers or spawn launcher a save changes, before → after", () => {
    const d = doc();
    const rows = rowsFrom(d, commands).map((r) => (r.key === "hermes" ? { ...r, use: true } : r));
    expect(typeChanges(d, applyRows(d, commands, rows, "hermes"))).toEqual([
      {
        type: "lead",
        label: "lead",
        launchers: [
          ["claude", "old"],
          ["hermes", "claude"],
        ],
        spawn: ["claude", "hermes"],
      },
      { type: "worker", label: "worker", launchers: [["claude"], ["hermes", "claude"]], spawn: ["", "hermes"] },
    ]);
  });

  it("an untouched page changes nothing: one launcher and no spawn launcher stay so", () => {
    const d: AgentDoc = {
      launchers: [{ key: "claude", label: "claude", ...claude }],
      agent_types: [type("lead"), type("worker", { launcher_follows: "lead" })],
    };
    const rows = rowsFrom(d, commands);
    const out = applyRows(d, commands, rows, defaultFrom(d, rows));
    expect(typeChanges(d, out)).toEqual([]);
    expect(out).toEqual(d);
    expect("spawn_launcher" in out.agent_types[0]!).toBe(false);
  });

  it("an unchanged type is not listed", () => {
    const d = doc();
    d.launchers = [d.launchers[0]!];
    d.agent_types = [type("lead", { spawn_launcher: "claude" })];
    expect(typeChanges(d, applyRows(d, commands, rowsFrom(d, commands), "claude"))).toEqual([]);
  });
});
