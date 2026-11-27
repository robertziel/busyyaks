// Settings → Agents & launchers: the revision ↔ form round trip and the edits that keep a type consistent.
import { describe, expect, it } from "vitest";
import {
  colorClashes,
  faceColor,
  freeColor,
  typeTags,
  fromDraft,
  fromPreset,
  invocationIndex,
  invocationLine,
  newLauncher,
  newType,
  presetsLeft,
  removeLauncher,
  renameLauncher,
  sameDoc,
  toDraft,
  toggleLauncher,
  withInvocation,
  type AgentDoc,
  type Invocation,
  type Preset,
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
      under: "lead",
    },
  ],
};

describe("agent settings form", () => {
  it("round-trips a revision unchanged", () => {
    expect(fromDraft(toDraft(doc))).toEqual(doc);
    expect(sameDoc(fromDraft(toDraft(doc)), doc)).toBe(true);
  });

  it("a save keeps a spawn-only type off the Launch bar and the lead's button text (launchable, launch_label)", () => {
    const spawned: AgentDoc = {
      ...doc,
      agent_types: [
        { ...doc.agent_types[0]!, label: "Team lead", launch_label: "Launch team lead" },
        { ...doc.agent_types[1]!, launchable: false },
      ],
    };
    expect(fromDraft(toDraft(spawned))).toEqual(spawned);
    const d = toDraft(spawned);
    expect([d.types[0]!.launchable, d.types[0]!.launchLabel, d.types[1]!.launchable]).toEqual([
      true,
      "Launch team lead",
      false,
    ]);
    d.types[0]!.launchLabel = "  ";
    d.types[1]!.launchable = true;
    const out = fromDraft(d).agent_types;
    expect("launch_label" in out[0]!).toBe(false);
    expect("launchable" in out[1]!).toBe(false);
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
    d.types[1]!.under = "";
    const out = fromDraft(d).agent_types;
    expect(out[0]!.prompt).toBeNull();
    expect(Object.keys(out[1]!)).not.toContain("under");
  });

  it("unticking a launcher drops its model", () => {
    const t = toggleLauncher(toDraft(doc).types[1]!, "fullclaude", false);
    expect(t.launchers).toEqual(["local"]);
    expect(t.models).toEqual({ local: "" });
    expect(toggleLauncher(t, "fullclaude", true).launchers).toEqual(["local", "fullclaude"]);
  });

  it("renaming or removing a launcher follows through every type", () => {
    const r = renameLauncher(toDraft(doc), 0, "claude");
    expect(r.launchers[0]!.key).toBe("claude");
    expect(r.types[1]!.launchers).toEqual(["claude", "local"]);
    expect(r.types[1]!.models).toEqual({ claude: "opus", local: "" });
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

  // config/agent_presets.yml → "Add preset": the lead's launchers, opt_in kept through the form
  it("a preset adds an opt-in type on its lead's launchers, and is offered once", () => {
    const preset: Preset = {
      key: "copywriter",
      label: "Copywriter",
      description: "Writes the words people read.",
      model: null,
      prompt: "Copywriter for {slug}",
      agent_name: "copywriter-{session}",
      session_name: "by_{slug}_copywriter",
      takes: [],
      max: 0,
      max_per_project: 0,
      under: "lead",
      launchable: false,
      opt_in: true,
    };
    const d = toDraft(doc);
    const t = fromPreset(d, preset);
    expect([t.key, t.launchers, t.under, t.launchable, t.optIn]).toEqual([
      "copywriter",
      ["fullclaude", "local"],
      "lead",
      false,
      true,
    ]);
    const saved = fromDraft({ ...d, types: [...d.types, t] }).agent_types.at(-1)!;
    expect([saved.opt_in, saved.launchable, saved.under]).toEqual([true, false, "lead"]);
    expect(presetsLeft({ ...d, types: [...d.types, t] }, [preset])).toEqual([]);
    expect(presetsLeft(d, [preset])).toEqual([preset]);
    // no such lead in the draft: no launcher (the save is refused naming it), never one guessed
    expect(fromPreset(d, { ...preset, under: "boss" }).launchers).toEqual([]);
    // a type that is not opt-in saves without the key
    expect(fromDraft(d).agent_types.every((x) => !("opt_in" in x))).toBe(true);
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

describe("type colours", () => {
  const palette = {
    colors: { blue: "var(--vivid-blue)", pink: "var(--vivid-pink)", teal: "var(--vivid-teal)" },
    face_theme: { lead: "var(--vivid-blue)" },
  };
  it("a type wears its own colour, else the theme's for its key, else none (the hashed hue); a colour round-trips", () => {
    const d = toDraft(doc);
    const lead = d.types.find((t) => t.key === "lead")!;
    expect(faceColor(lead, palette)).toBe("var(--vivid-blue)");
    expect(faceColor({ ...lead, color: "pink" }, palette)).toBe("var(--vivid-pink)");
    expect(faceColor({ key: "nobody", color: "" }, palette)).toBeNull();
    expect(fromDraft({ ...d, types: [{ ...lead, color: "teal" }] }).agent_types[0]!.color).toBe("teal");
    expect(fromDraft(d).agent_types.some((t) => "color" in t)).toBe(false);
  });
  it("a new type gets the first colour nobody wears; a shared colour is named on both", () => {
    const d = toDraft(doc);
    expect(freeColor(d, palette)).toBe("pink");
    const two = { ...d, types: d.types.map((t) => ({ ...t, color: "teal" })) };
    const clash = colorClashes(two, palette);
    expect(clash[0]).toEqual(two.types.slice(1).map((t) => t.key));
    expect(colorClashes(d, palette).every((c) => c === undefined)).toBe(true);
  });
  it("tags say what a type is", () => {
    const t = toDraft(doc).types[0]!;
    expect(typeTags({ ...t, under: "", standalone: false, launchable: true, optIn: false, takes: [] })).toEqual([
      "lead",
      "Launch bar",
    ]);
    expect(typeTags({ ...t, under: "lead", launchable: false, optIn: true, takes: ["working"] })).toEqual([
      "under lead",
      "spawned by its lead",
      "opt-in per board",
      "takes working",
    ]);
  });
});
