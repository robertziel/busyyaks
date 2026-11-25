// the lanes rendered — Needs you with its answer buttons (a dialog's keys, a question's choices), Working
// chips with the phase + card + time, Quiet pills folded past the limit, the detail strip of the selected chip with its
// explicit "Open terminal", the ⋯ menus (no open buttons on the rows), and one tab stop per chip.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { buildLanes, CHIP_START, QUIET_LIMIT, type ChipState } from "../lib/sessionLanes";
import type { AgentSession, TmuxSession } from "../types";
import type { RegisteredSession } from "../vendor/agents_kanban";
import { SessionLanesView, sessionMenuItems, type ViewProps } from "./SessionLanes";

// every fixture session is one busyyaks runs (an open registration): the lanes show nothing else
const registered = (list: TmuxSession[]) =>
  list.map((t) => ({ session: t.name, type: "worker", launcher: "fullclaude" }) as RegisteredSession);

const tmux = (name: string, created = 1): TmuxSession => ({
  name,
  created,
  attached: false,
  terminal_url: `https://t/${name}`,
  claude_url: name === "p_lead" ? "https://claude.ai/code/x" : null,
  ssh_attach: `ssh h -t tmux attach -t ${name}`,
});
const agent = (name: string, state: AgentSession["state"], o: Partial<AgentSession> = {}): AgentSession =>
  ({
    key: `default/${name}`,
    name,
    socket: "default",
    state,
    state_by: null,
    unread: false,
    phase: null,
    live: { tool: null, elapsed_s: null, tokens: null, card: null },
    cards: [],
    asks: [],
    reviews: [],
    dialogs: [],
    waiting_for: [],
    agent: null,
    agent_type: null,
    ...o,
  }) as AgentSession;
const card = (id: number, title: string) => ({
  id,
  slug: "p",
  title,
  column_label: "In progress",
  column_type: "working",
  gate_hold: null,
  blocked_external: null,
  approved_carried_on: false,
  path: `/projects/p?tab=board&card=${id}`,
});

const sessions = [tmux("p_dialog", 9), tmux("p_ask", 8), tmux("p_tool", 7), tmux("p_think", 6), tmux("p_lead", 5)];
const agents = [
  agent("p_dialog", "blocked", {
    dialogs: [
      {
        question: "Permission: Bash",
        command: "docker compose run --rm test",
        options: [
          { key: "1", label: "Yes", free: false },
          { key: "3", label: "No, and tell Claude", free: true },
        ],
        escape: true,
        free_text: true,
        hash: "h1",
        answerable: true,
      },
    ],
    cards: [card(471, "Board focus trap")],
  }),
  agent("p_ask", "blocked", {
    asks: [
      {
        id: 469,
        slug: "p",
        title: "Host patch",
        question: "Rebase or split?",
        options: ["Rebase", "Split PR"],
        path: "/projects/p?tab=board&card=469",
      },
    ],
  }),
  agent("p_tool", "working", {
    phase: "tool",
    live: { tool: "Bash", elapsed_s: 252, tokens: "↓ 38.2k", card: 470 },
    cards: [card(470, "CI read correctness")],
  }),
  agent("p_think", "working", { phase: null, cards: [] }),
  agent("p_lead", "finished"),
];

const view = (o: Partial<ViewProps> = {}, list = sessions, live: AgentSession[] | null = agents) =>
  renderToStaticMarkup(
    createElement(
      MemoryRouter,
      null,
      createElement(SessionLanesView, {
        lanes: buildLanes(list, live, registered(list)),
        chip: CHIP_START,
        dispatch: () => {},
        quietOpen: false,
        onQuietOpen: () => {},
        busy: null,
        stop: () => {},
        launch: createElement("span", { className: "fake-launch" }, "LAUNCH"),
        issue: null,
        ...o,
      }),
    ),
  );
const count = (html: string, re: RegExp) => (html.match(re) ?? []).length;

describe("SessionLanesView", () => {
  it("three lanes in order, each with its count; the launch bar + Stop all in the Quiet lane", () => {
    const html = view();
    const at = (s: string) => html.indexOf(s);
    expect(at("Needs you <span>2</span>")).toBeGreaterThan(-1);
    expect(at("Working <span>2</span>")).toBeGreaterThan(at("Needs you"));
    expect(at("Quiet <span>1</span>")).toBeGreaterThan(at("Working"));
    expect(at("LAUNCH")).toBeGreaterThan(at("Quiet"));
    expect(html).toContain('aria-label="All sessions actions"');
  });

  it("Needs you: a dialog's keys (free text disabled, Esc) and a question's choices as buttons", () => {
    const html = view();
    expect(html).toContain("Permission: Bash");
    expect(html).toContain("<code>docker compose run --rm test</code>");
    expect(html).toMatch(/<button[^>]*title="Press 1 in p_dialog"[^>]*>1\. Yes<\/button>/);
    expect(html).toMatch(
      /<button[^>]*disabled=""[^>]*title="free text: answer in the session"[^>]*>3\. No, and tell Claude/,
    );
    expect(html).toMatch(/title="Press Esc in p_dialog"[^>]*>Esc</);
    expect(html).toContain("Rebase or split?");
    expect(html).toMatch(/title="Post this as your answer on the card"[^>]*>Rebase</);
    expect(html).toMatch(/title="Post this as your answer on the card"[^>]*>Split PR</);
    expect(html).toContain('href="/projects/p?tab=board&amp;card=469"');
  });

  it("Quiet: a session waiting for CI links its held card's #id (an idle session has no screen card)", () => {
    const held = { ...card(12, "Held at the gate"), gate_hold: "CI pending" };
    const html = view({}, [tmux("p_idle", 1)], [agent("p_idle", "idle", { cards: [card(11, "Other"), held] })]);
    expect(html).toContain("waiting for CI");
    expect(html).toContain('href="/projects/p?tab=board&amp;card=12"');
    expect(html).not.toContain("card=11");
  });

  it("an unanswered Agents read: every session says its live state is unknown, never 'no live state'", () => {
    const html = view({}, [tmux("p_a", 2), tmux("p_b", 1)], null);
    expect(html).toContain('aria-label="p_a: live state unknown. Open terminal"');
    expect(html).toContain('aria-label="p_b: live state unknown. Open terminal"');
    expect(html).not.toContain("no live state");
  });

  it("Working: the phase (a tool with its name; no evidence = working), the card linked, the turn's time", () => {
    const html = view();
    expect(html).toContain('aria-label="p_tool: tool · Bash. Open terminal"');
    expect(html).toContain("4m 12s");
    expect(html).toContain('href="/projects/p?tab=board&amp;card=470"');
    expect(html).toContain('aria-label="p_think: working. Open terminal"');
  });

  it("no Claude / iTerm / Terminal buttons on the rows: one main button + one ⋯ per chip; names are short", () => {
    const html = view();
    expect(html).not.toMatch(/Claude ↗|iTerm ⧉|Terminal ↗/);
    expect(count(html, /class="lane-main"/g)).toBe(5);
    // the short name on the chip, the full one in its title; CSS cuts it with an ellipsis
    expect(html).toContain('<span class="lane-name mono" title="p_dialog">dialog</span>');
    // every chip / pill / card carries its own ⋯ (5) + the section's (Stop all): reachable without the strip
    expect(count(html, /aria-haspopup="menu"/g)).toBe(6);
    for (const n of ["p_dialog", "p_ask", "p_tool", "p_think", "p_lead"])
      expect(html).toContain(`aria-label="${n} actions"`);
  });

  it("the selected chip's strip: full name, tool, time · tokens, an explicit Open terminal (the touch path)", () => {
    const chip: ChipState = { selected: "p_tool", by: "tap", open: null };
    const html = view({ chip });
    expect(html).toContain('id="lane-strip"');
    expect(html).toContain("p_tool · worker · fullclaude");
    expect(html).toContain("4m 12s · ↓ 38.2k");
    expect(html).toMatch(/<button[^>]*>Open terminal<\/button>/);
    expect(html).toContain('aria-describedby="lane-strip"');
    const strip = html.slice(html.indexOf('id="lane-strip"'));
    expect(strip.slice(0, strip.indexOf("</div>"))).not.toContain("aria-haspopup"); // its menu is on the chip
    expect(view()).not.toContain('id="lane-strip"');
  });

  it("a session with no live state: quiet, said so, and its strip offers no terminal", () => {
    const html = view({ chip: { selected: "p_x", by: "tap", open: null } }, [tmux("p_x"), tmux("p_y")], []);
    expect(html).toContain("no live state");
    expect(html).toContain('aria-disabled="true"');
    expect(html).not.toMatch(/>Open terminal</);
  });

  it(`Quiet folds past ${QUIET_LIMIT} behind "+N quiet" (aria-expanded); expanded shows every pill`, () => {
    const many = Array.from({ length: QUIET_LIMIT + 3 }, (_, i) => tmux(`p_q${i}`, 50 - i));
    const quiet = many.map((s) => agent(s.name, "idle"));
    const folded = view({}, many, quiet);
    expect(count(folded, /class="lane-quiet/g)).toBe(QUIET_LIMIT);
    expect(folded).toMatch(/aria-expanded="false"[^>]*>\+3 quiet</);
    const open = view({ quietOpen: true }, many, quiet);
    expect(count(open, /class="lane-quiet/g)).toBe(QUIET_LIMIT + 3);
    expect(open).toMatch(/aria-expanded="true"[^>]*>fewer</);
  });

  it("the Agents read failed before its first answer: said above the lanes, as an alert", () => {
    const html = view({ issue: { kind: "none", text: "live state unknown: 503 launcher down" } });
    expect(html).toMatch(/<p class="lanes-err" role="alert">.*live state unknown: 503 launcher down/);
  });

  // a failed refresh / stale snapshot / collector error never shows the last snapshot as live
  it("the last snapshot: the reason as an alert, the lanes dimmed (no pulse), every answer button off", () => {
    const issue = { kind: "old" as const, text: "showing the last snapshot: refresh failed: 502" };
    const html = view({ issue });
    expect(html).toMatch(/role="alert">.*showing the last snapshot: refresh failed: 502/);
    expect(html).toContain('class="lanes stale"');
    const answers = html.match(/<button[^>]*title="(Press [^"]*|Post this as your answer on the card)"/g) ?? [];
    expect(answers).toEqual([]); // no live-answer title left
    const off = html.match(/<button[^>]*disabled=""[^>]*title="the live read is old[^"]*"/g) ?? [];
    expect(off.length).toBe(5); // 1. Yes · 3. No (free) · Esc · Rebase · Split PR
    expect(html).toContain('aria-label="p_tool: tool · Bash (last snapshot). Open terminal"');
    const fresh = view();
    expect(fresh).toContain('class="lanes"');
    expect(fresh).toMatch(/title="Press 1 in p_dialog"/);
  });

  // the phase word is its own never-cut span; the tool's name a separate suffix the chip shortens first
  it("a Working chip's phase: the word whole, the tool's name apart; the CSS cuts only the name", () => {
    const html = view();
    expect(html).toMatch(/<span class="lane-st-w">tool<\/span><span class="lane-st-tool">· Bash<\/span>/);
    expect(html).toMatch(/<span class="lane-st-w">working<\/span><\/span>/);
    const css = readFileSync(join(__dirname, "..", "styles", "projects.css"), "utf8").replace(/\s+/g, " ");
    expect(css).toContain(".lane-st-w { flex: none; }");
    expect(css).toMatch(
      /\.lane-st-tool \{ min-width: 0; flex: 0 1000 auto; overflow: hidden; text-overflow: ellipsis;/,
    );
  });

  // a hover never opens the strip (it pushed every lane below while the pointer travelled)
  it("no hover handler anywhere in the lanes: only focus, a tap or a click change what is shown", () => {
    const src = readFileSync(join(__dirname, "SessionLanes.tsx"), "utf8");
    expect(src).not.toMatch(/onMouseEnter|onMouseLeave|onPointerEnter|onPointerLeave|onMouseOver/);
    expect(src).toContain(":focus-visible");
  });

  // a Quiet pill's ⋯ menu dropped over the board and was painted under it (Stop unreachable by mouse)
  it("a Quiet pill carries its own ⋯, whose entries end in Stop session (it stops exactly that session)", () => {
    const html = view();
    const pill = html.slice(
      html.indexOf('<div class="lane-quiet'),
      html.indexOf("</div>", html.indexOf('<div class="lane-quiet')),
    );
    expect(pill).toMatch(/<button[^>]*class="lane-kebab"[^>]*aria-label="p_lead actions"[^>]*aria-haspopup="menu"/);
    const calls: [string[], string][] = [];
    const lane = buildLanes(sessions, agents, registered(sessions)).quiet[0]!;
    const items = sessionMenuItems(lane, null, (n, w) => calls.push([n, w]));
    expect(items.map((i) => i.label)).toEqual([
      "Open in Claude app",
      "Copy iTerm attach",
      "Open external terminal",
      "Copy tmux attach",
      "Stop session",
    ]);
    const stopItem = items.at(-1)!;
    expect([stopItem.danger, stopItem.off]).toEqual([true, undefined]);
    stopItem.run!();
    expect(calls).toEqual([[["p_lead"], "p_lead"]]);
    expect(sessionMenuItems(lane, "other", () => {}).at(-1)!.off).toBe("a stop is running");
  });

  // the menu is a portal into <body> (inside the lanes' card the board painted over it), fixed in place
  it("the ⋯ menu renders into document.body, fixed, above the page (the card peek too); the lanes' card adds no z-index of its own", () => {
    const src = readFileSync(join(__dirname, "SessionLanes.tsx"), "utf8").replace(/\s+/g, " ");
    expect(src).toMatch(/createPortal\( <div className=\{`lane-pop.*?document\.body, \)/);
    const css = readFileSync(join(__dirname, "..", "styles", "projects.css"), "utf8").replace(/\s+/g, " ");
    expect(css).toMatch(/\.lane-pop \{ position: fixed; z-index: 1001;/);
    expect(css.match(/\.launchbar \{[^}]*\}/)![0]).not.toContain("z-index");
    const peek = readFileSync(join(__dirname, "..", "vendor", "agents_kanban", "styles", "kanban.css"), "utf8")
      .replace(/\s+/g, " ")
      .match(/\.ak-root\.kb-peek \{[^}]*z-index: (\d+);/)![1];
    expect(1001).toBeGreaterThan(Number(peek));
    expect(css).not.toContain(".launchbar:has(");
  });

  // the menu is a portal in <body>, outside .lanes — nothing it draws may hang on .lanes / .launchbar
  it("the ⋯ menu's styles stand on their own: an unscoped focus ring, and every token it reads defined for it", () => {
    const read = (...f: string[]) => readFileSync(join(__dirname, ...f), "utf8");
    const css = read("..", "styles", "projects.css")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\s+/g, " ");
    const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sel: m[1]!.trim(), body: m[2]! }));
    expect(css).toContain(
      '.lane-pop [role="menuitem"]:focus-visible { outline: 2px solid var(--live); outline-offset: -2px; }',
    );
    const menu = rules.filter((r) => /\.lane-(pop|mi)\b/.test(r.sel));
    for (const r of menu) expect(r.sel).not.toMatch(/(^|,\s*)\.(lanes|launchbar|lane-menu)\s+\.lane-(pop|mi)/);
    // the tokens it reads: none may be one a local block sets (like the lanes' own --live on .lanes) unless a block
    // naming .lane-pop sets it too — skin colours and :root tokens are everywhere, local ones are not
    const local = (r: { sel: string }) => !/(^|,\s*):root(\[[^\]]*\])*(\s*,|$)/.test(r.sel); // :root, :root[data-skin=…]
    const declared = (pick: (r: { sel: string }) => boolean) =>
      new Set(rules.filter(pick).flatMap((r) => [...r.body.matchAll(/(--[\w-]+)\s*:/g)].map((m) => m[1]!)));
    const scoped = declared(local);
    const forMenu = declared((r) => /(^|,\s*)\.lane-pop(\s*,|$)/.test(r.sel));
    const used = new Set(menu.flatMap((r) => [...r.body.matchAll(/var\((--[\w-]+)/g)].map((m) => m[1]!)));
    expect([...used].filter((v) => scoped.has(v) && !forMenu.has(v))).toEqual([]);
    expect(used.has("--live")).toBe(true);
  });
});
