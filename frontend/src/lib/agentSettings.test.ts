// Settings → Agents & launchers: the revision ↔ form round trip and the edits that keep a type consistent.
import { describe, expect, it } from "vitest";
import {
  fromDraft,
  invocationIndex,
  invocationLine,
  newLauncher,
  newType,
  removeLauncher,
  renameLauncher,
  sameDoc,
  toDraft,
  toggleLauncher,
  withInvocation,
  type AgentDoc,
  type Invocation,
} from "./agentSettings";

const doc: AgentDoc = {
  launchers: [
    {
      key: "fullclaude",
      label: "fullclaude",
      kind: "claude_code",
      command: "claude",
      args: ["--permission-mode", "bypassPermissions"],
      via_shell: false,
    },
    { key: "local", label: "local", kind: "claude_code", command: "localclaude", args: [], via_shell: true },
  ],
  agent_types: [
    {
      key: "lead",
      label: "Launch",
      launchers: ["fullclaude", "local"],
      model: null,
      prompt: "for {slug}",
      agent_name: "claude-{session}",
      session_name: "{slug}_teamlead",
      takes: ["gate"],
      max: 0,
      max_per_project: 1,
    },
    {
      key: "worker",
      label: "Worker",
      launchers: ["fullclaude", "local"],
      model: { fullclaude: "opus", local: null },
      prompt: null,
      agent_name: "worker-{session}",
      session_name: "{slug}_worker",
      takes: [],
      max: 0,
      max_per_project: 0,
      spawns_for: ["queued", "working"],
      launcher_follows: "lead",
      spawn_launcher: "fullclaude",
    },
  ],
};

describe("agent settings form", () => {
  it("round-trips a revision unchanged", () => {
    expect(fromDraft(toDraft(doc))).toEqual(doc);
    expect(sameDoc(fromDraft(toDraft(doc)), doc)).toBe(true);
  });

  it("a model is null when no launcher sets one, else a map naming exactly the type's launchers", () => {
    const d = toDraft(doc);
    d.types[0]!.models.local = " sonnet ";
    expect(fromDraft(d).agent_types[0]!.model).toEqual({ fullclaude: null, local: "sonnet" });
    d.types[1]!.models = { fullclaude: "", local: "" };
    expect(fromDraft(d).agent_types[1]!.model).toBeNull();
  });

  it("a one-value model becomes the same value per launcher", () => {
    const one = { ...doc, agent_types: [{ ...doc.agent_types[0]!, model: "opus" }] };
    expect(fromDraft(toDraft(one)).agent_types[0]!.model).toEqual({ fullclaude: "opus", local: "opus" });
  });

  it("a prompt switched off is null; optional keys are left out when unset", () => {
    const d = toDraft(doc);
    d.types[0]!.hasPrompt = false;
    d.types[1]!.launcher_follows = "";
    d.types[1]!.spawn_launcher = "";
    d.types[1]!.spawns_for = [];
    const out = fromDraft(d).agent_types;
    expect(out[0]!.prompt).toBeNull();
    expect(Object.keys(out[1]!)).not.toContain("launcher_follows");
    expect(Object.keys(out[1]!)).not.toContain("spawn_launcher");
    expect(Object.keys(out[1]!)).not.toContain("spawns_for");
  });

  it("unticking a launcher drops its model and a spawn_launcher naming it", () => {
    const t = toggleLauncher(toDraft(doc).types[1]!, "fullclaude", false);
    expect(t.launchers).toEqual(["local"]);
    expect(t.models).toEqual({ local: "" });
    expect(t.spawn_launcher).toBe("");
    expect(toggleLauncher(t, "fullclaude", true).launchers).toEqual(["local", "fullclaude"]);
  });

  it("renaming or removing a launcher follows through every type", () => {
    const r = renameLauncher(toDraft(doc), 0, "claude");
    expect(r.launchers[0]!.key).toBe("claude");
    expect(r.types[1]!.launchers).toEqual(["claude", "local"]);
    expect(r.types[1]!.models).toEqual({ claude: "opus", local: "" });
    expect(r.types[1]!.spawn_launcher).toBe("claude");
    const x = removeLauncher(toDraft(doc), 1);
    expect(x.launchers.map((l) => l.key)).toEqual(["fullclaude"]);
    expect(x.types.map((t) => t.launchers)).toEqual([["fullclaude"], ["fullclaude"]]);
  });

  it("a launcher is one of the host's invocations: matched exactly, picked whole, new = the first", () => {
    const allow: Invocation[] = [
      { kind: "claude_code", command: "claude", args: ["--permission-mode", "bypassPermissions"], via_shell: false },
      { kind: "claude_code", command: "localclaude", args: [], via_shell: true },
      { kind: "hermes", command: "hermes", args: ["chat"], via_shell: false },
    ];
    expect(doc.launchers.map((l) => invocationIndex(allow, l))).toEqual([0, 1]);
    expect(
      invocationIndex(allow, { ...doc.launchers[0]!, args: ["--permission-mode", "bypassPermissions", "--x"] }),
    ).toBe(-1);
    expect(invocationIndex(allow, { ...doc.launchers[1]!, via_shell: false })).toBe(-1);
    const h = withInvocation(doc.launchers[0]!, allow[2]!);
    expect([h.key, h.label, h.kind, h.command, h.args, h.via_shell]).toEqual([
      "fullclaude",
      "fullclaude",
      "hermes",
      "hermes",
      ["chat"],
      false,
    ]);
    expect(newLauncher(allow)).toEqual({ key: "", label: "", ...allow[0]! });
    expect(invocationLine(allow[1]!)).toBe("Claude Code · localclaude (via shell)");
    expect(invocationLine(allow[2]!)).toBe("hermes · hermes chat");
  });

  it("a new type runs the first launcher with no prompt and no cap", () => {
    const t = newType(doc.launchers);
    expect([t.launchers, t.models, t.hasPrompt, t.max, t.max_per_project]).toEqual([
      ["fullclaude"],
      { fullclaude: "" },
      false,
      0,
      0,
    ]);
  });
});
