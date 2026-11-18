// the hello screen's launcher rows → the agent settings document it saves.
import { describe, expect, it } from "vitest";
import type { AgentDoc, AgentType, Invocation } from "./agentSettings";
import {
  applyPhase,
  childPath,
  crumbs,
  failureParts,
  parentPath,
  agentPrompt,
  applyRows,
  typeChanges,
  defaultFrom,
  rowsError,
  rowsFrom,
  setupPending,
  stepFrom,
  harnessState,
  harnessLine,
  usedMissing,
  draftDirty,
  keepDefault,
  type Harness,
  type HarnessesData,
  type RootStatus,
  type SetupData,
} from "./hello";

const claude: Invocation = {
  kind: "claude_code",
  command: "claude",
  args: [],
  via_shell: false,
};
const local: Invocation = {
  kind: "claude_code",
  command: "localclaude",
  args: [],
  via_shell: true,
};
const hermes: Invocation = {
  kind: "hermes",
  command: "hermes",
  args: ["chat"],
  via_shell: false,
};
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
    {
      key: "old",
      label: "old",
      kind: "claude_code",
      command: "gone",
      args: [],
      via_shell: false,
    },
  ],
  agent_types: [
    type("lead", {
      launchers: ["claude", "old"],
      model: { claude: "opus", old: null },
    }),
    type("worker", { under: "lead" }),
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
      {
        key: "localclaude",
        label: "localclaude",
        at: 1,
        use: false,
        existing: false,
      },
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
  it("the lead's first launcher while it is in use, else the first in use", () => {
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
  it("drops the launcher on no allowlist entry, adds the picked commands, the default first", () => {
    const rows = rowsFrom(doc(), commands).map((r) => (r.key === "hermes" ? { ...r, use: true, label: "Hermes" } : r));
    const out = applyRows(doc(), commands, rows, "hermes");
    expect(out.launchers).toEqual([
      { key: "claude", label: "claude", ...claude },
      { key: "hermes", label: "Hermes", ...hermes },
    ]);
    const lead = out.agent_types[0]!;
    expect(lead.launchers).toEqual(["hermes", "claude"]);
    expect("spawn_launcher" in lead).toBe(false);
    expect(lead.model).toEqual({ hermes: null, claude: "opus" });
    expect(lead.prompt).toBe("p");
    const worker = out.agent_types[1]!;
    expect(worker.launchers).toEqual(["hermes", "claude"]);
    expect(worker.under).toBe("lead");
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
    expect(text).toContain("PROJECTS_ROOT /srv/code holds 3 repos — leave it.");
    expect(text).toContain("then restart both: deploy/install-launcher.sh && docker compose restart web.");
    expect(text).toContain("launch.commands allows claude, hermes chat.");
  });

  it("carries the harness detection: what is found, what to install, the exact line to add", () => {
    const p = {
      host_root: "/srv",
      mount: "/p",
      roots: [],
      search_depth: 2,
      repos: 0,
      sample: [],
    };
    const data: HarnessesData = {
      checked_at: 0,
      elapsed_ms: 1,
      shell: "bash -ic",
      harnesses: [
        h({ key: "claude", command: "claude", version: "2.1.3", allowed: [0] }),
        h({
          key: "hermes",
          command: "hermes",
          kind: "hermes",
          allow_line: "- { kind: hermes, command: hermes }",
        }),
        h({
          key: "codex",
          command: "codex",
          found: false,
          kind: null,
          launchable: false,
          allow_line: null,
        }),
      ],
      commands: [],
      allowlist_in_sync: true,
    };
    const text = agentPrompt(p, [claude], "https://d", { data });
    expect(text).toContain("/srv and holds no git repo. Point it at the folder");
    expect(text).toContain("Ask me before adding anything else");
    expect(text).toContain("Harnesses on this host: claude 2.1.3, hermes 1.0 (not allowed), codex not found.");
    expect(text).toContain("Install if I want them: codex https://x.example");
    expect(text).toContain("Add exactly: - { kind: hermes, command: hermes }");
    expect(agentPrompt(p, [claude], "https://d", { error: "503 · launcher down" })).toContain(
      "Harness check unavailable: 503 · launcher down. Start the launcher first",
    );
  });
});

const h = (over: Partial<Harness>): Harness => ({
  key: "x",
  label: "X",
  command: "x",
  install_url: "https://x.example",
  kind: "claude_code",
  launch_args: [],
  launchable: true,
  found: true,
  type: "file",
  path: "/bin/x",
  version: "1.0",
  version_error: null,
  allowed: [],
  allow_line: "- { kind: claude_code, command: x, args: [], via_shell: false }",
  allow_note: null,
  ...over,
});

describe("stepFrom", () => {
  it("the URL's step, else Checks on a first run and Summary on a reopen", () => {
    expect(stepFrom("agents", false)).toBe("agents");
    expect(stepFrom(null, false)).toBe("checks");
    expect(stepFrom(null, true)).toBe("summary");
    expect(stepFrom("nope", true)).toBe("summary");
  });
});

describe("harnessState", () => {
  it("every card state, glyph + word", () => {
    expect(harnessState(h({ allowed: [0] }))).toEqual({
      key: "found",
      badge: "✓ found",
      tone: "ok",
    });
    expect(harnessState(h({ allowed: [] })).key).toBe("not_allowed");
    expect(
      harnessState(
        h({
          allowed: [0],
          version: null,
          version_error: "timed out after 5 s",
        }),
      ).tone,
    ).toBe("warn");
    expect(harnessState(h({ allowed: [0], type: "function", path: null })).key).toBe("shell");
    expect(harnessState(h({ found: false })).key).toBe("missing");
    expect(harnessState(h({ found: false, allowed: [1] })).key).toBe("missing_allowed");
    // the program is not on PATH but an allowlisted command of its kind is: a warning, not "nothing runs"
    const found = [{ at: 1, found: true, type: "file", path: "/b/readme-agent" }];
    expect(harnessState(h({ found: false, allowed: [1] }), found)).toEqual({
      key: "missing_runs",
      badge: "! not on PATH · allowed command found",
      tone: "warn",
    });
    expect(harnessState(h({ found: false, allowed: [1] }), [{ ...found[0]!, found: false }]).key).toBe(
      "missing_allowed",
    );
    expect(harnessState(h({ kind: null, launchable: false, allowed: [] })).key).toBe("found");
    // a shell function of a kind that needs a program: never launchable, whatever else of its kind is allowed
    const fn = h({
      type: "function",
      path: null,
      allowed: [0],
      allow_line: null,
      allow_note: "hermes is a shell function",
    });
    expect(harnessState(fn)).toEqual({
      key: "shell_unlaunchable",
      badge: "! shell function · not launchable",
      tone: "warn",
    });
    expect(harnessLine({ ...fn, command: "hermes", version: null })).toBe("hermes shell function (not launchable)");
  });

  it("one line: version, shell kind, not found, not launchable", () => {
    expect(harnessLine(h({ command: "claude", version: "2.1", allowed: [0] }))).toBe("claude 2.1");
    expect(harnessLine(h({ command: "claude", version: "2.1" }))).toBe("claude 2.1 (not allowed)");
    expect(
      harnessLine(h({ command: "claude", version: "2.1", allowed: [0] }), [
        { at: 0, found: false, type: null, path: null },
      ]),
    ).toBe("claude 2.1 (allowed command ✗)");
    expect(harnessLine(h({ command: "f", version: null, type: "function", allowed: [0] }))).toBe("f shell function");
    expect(harnessLine(h({ command: "c", found: false }))).toBe("c not found");
    expect(harnessLine(h({ command: "codex", launchable: false }))).toBe("codex 1.0 (not supported yet)");
    expect(
      harnessLine(
        h({
          command: "x",
          version: null,
          version_error: "timed out after 5 s",
          allowed: [0],
        }),
      ),
    ).toBe("x version ✗ (timed out after 5 s)");
    const found = [{ at: 1, found: true, type: "file", path: "/b/w" }];
    expect(harnessLine(h({ command: "hermes", found: false, allowed: [1] }), found)).toBe(
      "hermes not on PATH (allowed command found)",
    );
  });

  it("found, but one of its allowed commands is not: a warning", () => {
    const resolved = [
      { at: 0, found: true, type: "file", path: "/b/claude" },
      { at: 1, found: false, type: null, path: null },
    ];
    expect(harnessState(h({ allowed: [0, 1] }), resolved)).toEqual({
      key: "allowed_missing",
      badge: "✓ found · allowed command ✗",
      tone: "warn",
    });
    expect(harnessState(h({ allowed: [0] }), resolved).key).toBe("found");
  });
});

describe("usedMissing + draftDirty", () => {
  const rows = rowsFrom(doc(), commands);
  it("the launchers in use whose command the launch shell does not find", () => {
    const resolved = [
      { at: 0, found: false, type: null, path: null },
      { at: 1, found: true, type: "function", path: null },
    ];
    expect(usedMissing(rows, resolved)).toEqual(["claude"]);
    expect(usedMissing(rows, null)).toEqual([]);
  });
  it("the default follows the launchers in use", () => {
    const one = rows.map((r) => ({ ...r, use: r.key === "localclaude" }));
    expect(keepDefault(one, "claude")).toBe("localclaude");
    expect(keepDefault(rows, "claude")).toBe("claude");
    expect(
      keepDefault(
        rows.map((r) => ({ ...r, use: false })),
        "claude",
      ),
    ).toBe("");
  });
  it("a draft differs from its revision's rows", () => {
    expect(draftDirty(rows, "claude", rows, "claude")).toBe(false);
    expect(draftDirty(rows, "localclaude", rows, "claude")).toBe(true);
    expect(
      draftDirty(
        rows.map((r) => ({ ...r, use: true })),
        "claude",
        rows,
        "claude",
      ),
    ).toBe(true);
  });
});

describe("typeChanges", () => {
  it("lists each type whose launchers a save changes, before → after (a type under a lead marked)", () => {
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
        under: null,
      },
      // worker runs under the lead: listed, marked as following the lead's launcher
      {
        type: "worker",
        label: "worker",
        launchers: [["claude"], ["hermes", "claude"]],
        under: "lead",
      },
    ]);
  });

  it("an untouched page changes nothing", () => {
    const d: AgentDoc = {
      launchers: [{ key: "claude", label: "claude", ...claude }],
      agent_types: [type("lead"), type("worker", { under: "lead" })],
    };
    const rows = rowsFrom(d, commands);
    const out = applyRows(d, commands, rows, defaultFrom(d, rows));
    expect(typeChanges(d, out)).toEqual([]);
    expect(out).toEqual(d);
  });

  it("an unchanged type is not listed", () => {
    const d = doc();
    d.launchers = [d.launchers[0]!];
    d.agent_types = [type("lead")];
    expect(typeChanges(d, applyRows(d, commands, rowsFrom(d, commands), "claude"))).toEqual([]);
  });
});

describe("projects dir (card 532)", () => {
  const last = (state: "applying" | "done" | "failed" | "interrupted", to = "/srv") => ({
    state,
    from: "/old",
    to,
    at: "t",
    log: "l",
    env: "new" as const,
  });
  const st = (current: string, l: RootStatus["last"]): RootStatus => ({
    current,
    applying: false,
    last: l,
  });

  it("breaks a host dir into the picker's breadcrumb", () => {
    expect(crumbs("/")).toEqual([{ name: "/", path: "/" }]);
    expect(crumbs("/srv/data/projects")).toEqual([
      { name: "/", path: "/" },
      { name: "srv", path: "/srv" },
      { name: "data", path: "/srv/data" },
      { name: "projects", path: "/srv/data/projects" },
    ]);
    expect(crumbs("/srv/")).toEqual([
      { name: "/", path: "/" },
      { name: "srv", path: "/srv" },
    ]);
  });

  it("goes up even from a dir that could not be listed", () => {
    expect(parentPath("/srv/code")).toBe("/srv");
    expect(parentPath("/srv")).toBe("/");
    expect(parentPath("/")).toBe("/");
  });

  it("says which .env is in place after a failure, as recorded", () => {
    const base = {
      state: "failed" as const,
      from: "/old",
      to: "/srv",
      at: "t",
      log: "/s/l",
      error: "compose up exit 1",
    };
    expect(failureParts({ ...base, env: "restored", rolled_back: true })).toEqual({
      reason: "compose up exit 1",
      env: ".env restored",
      log: "/s/l",
    });
    expect(failureParts({ ...base, env: "restored", rolled_back: false }).env).toBe(
      ".env restored, rollback compose failed too",
    );
    expect(failureParts({ ...base, env: "new" }).env).toBe(".env still holds /srv");
    const cut = { ...base, state: "interrupted" as const, error: undefined, env: "new" as const, note: "not finished" };
    expect(failureParts(cut).reason).toBe("not finished");
    expect(failureParts({ ...cut, env: "unknown" as const }).env).toBe(
      ".env state not recorded: check PROJECTS_ROOT in .env",
    );
  });

  it("never shows the record's state as the reason: none recorded says so", () => {
    const l = { state: "failed" as const, from: "/old", to: "/srv", at: "t", log: "/s/l", env: "restored" as const };
    expect(failureParts(l).reason).toBe("reason not recorded");
  });

  it("joins a picked subdir", () => {
    expect(childPath("/", "srv")).toBe("/srv");
    expect(childPath("/srv", "code")).toBe("/srv/code");
  });

  it("follows an apply until the restarted launcher runs on the new dir", () => {
    expect(applyPhase(null, "/srv")).toBe("restarting");
    expect(applyPhase(st("/old", last("applying")), "/srv")).toBe("applying");
    // compose finished, the launcher not restarted yet: still the old dir
    expect(applyPhase(st("/old", last("done")), "/srv")).toBe("applying");
    expect(applyPhase(st("/srv", last("done")), "/srv")).toBe("done");
    expect(applyPhase(st("/old", last("failed")), "/srv")).toBe("failed");
    expect(applyPhase(st("/old", last("interrupted")), "/srv")).toBe("failed");
    // an older change's record never answers for this one
    expect(applyPhase(st("/old", last("failed", "/elsewhere")), "/srv")).toBe("applying");
  });
});
