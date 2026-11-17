// The "waiting for you" widget (kind counters): the counts per kind, the segments, the sheet's tabs, the
// loading / zero / error states, keyboard + focus, and the plate's text contrast in both skins.
import { readFileSync } from "node:fs";
import { createElement, isValidElement, type ReactElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { Link } from "react-router-dom";
import { escapeFocus, rowKey, sheetListeners, sheetMode, WaitingView } from "../components/Waiting";
import { monogram } from "../components/ProjectIcon";
import type { AgentsData } from "../types";
import {
  age,
  approvedLine,
  byKind,
  cardHref,
  KINDS,
  nextKind,
  nextRow,
  segmentLabel,
  type Kind,
  type Waiting,
  type WaitingCard,
} from "./waiting";

const AT = Date.parse("2025-03-04T22:00:00Z") / 1000;
const card = (id: number, kind: string, extra: Partial<WaitingCard> = {}): WaitingCard => ({
  id,
  title: `card ${id}`,
  column: kind === "ask" ? "doing" : "check_col",
  column_label: kind === "ask" ? "In progress" : "Human Check",
  kind,
  needs_operator: kind === "ask",
  blocked: kind === "external",
  since: null,
  question_first_line: null,
  owner_session: null,
  approved: null,
  approved_by: null,
  carried_on: null,
  ...extra,
});
const data: Waiting = {
  waiting_columns: ["check_col"],
  launch_failures: [],
  lead_ends: [],
  total: 4,
  projects: [
    {
      slug: "gadgets",
      icon: "/api/icons/gadgets?v=1",
      count: 3,
      cards: [
        card(42, "ask", {
          title: "Widget <b>",
          since: "2025-03-04T21:53:00Z",
          question_first_line: "Ship A or B?",
          owner_session: "tl_lead",
        }),
        card(43, "ask", { owner_session: "tl_gone" }),
        card(41, "review", { handoff_first_line: "open the preview" }),
      ],
    },
    { slug: "acme/widgets", icon: null, count: 1, cards: [card(7, "review")] },
  ],
  held: [
    {
      slug: "acme/widgets",
      icon: null,
      count: 1,
      cards: [card(8, "held", { gate_hold: "CI pending", handoff_first_line: "check the PR" })],
    },
  ],
  external: [
    {
      slug: "gadgets",
      icon: "/api/icons/gadgets?v=1",
      count: 1,
      cards: [card(9, "external", { blocked_first_line: "runner offline" })],
    },
  ],
  approved: [
    {
      slug: "gadgets",
      icon: "/api/icons/gadgets?v=1",
      count: 2,
      cards: [
        card(463, "approved", {
          column_label: "Awaiting merge",
          owner_session: "tl_lead",
          approved: "2025-03-04T21:50:00Z",
          approved_by: "op",
          carried_on: { next_column: "done", next_label: "Done", final: true },
        }),
        card(464, "approved", {
          column_label: "Awaiting merge",
          owner_session: "w_2",
          approved: "2025-03-04T21:51:00Z",
          approved_by: "op",
          carried_on: { next_column: "deploy", next_label: "Deploy check", final: false },
        }),
      ],
    },
  ],
};
const empty: Waiting = {
  waiting_columns: [],
  total: 0,
  projects: [],
  held: [],
  external: [],
  approved: [],
  launch_failures: [],
  lead_ends: [],
};
type Props = Parameters<typeof WaitingView>[0];
const render = (p: Omit<Props, "at">) =>
  renderToStaticMarkup(createElement(MemoryRouter, null, createElement(WaitingView, { ...p, at: AT })));
const session = (name: string, state: string, extra: object = {}) => ({
  key: `default/${name}`,
  name,
  socket: "default",
  state,
  state_by: null,
  dialogs: [],
  waiting_for: [],
  asks: [],
  reviews: [],
  ...extra,
});
const agentsData = {
  groups: [
    {
      label: "gadgets",
      slug: "gadgets",
      icon: null,
      state: "blocked",
      sessions: [
        session("tl_lead", "blocked", {
          dialogs: [
            { hash: "h", question: "Allow git push?", command: null, options: [], escape: true, answerable: true },
          ],
        }),
      ],
    },
  ],
} as unknown as AgentsData;

// the host elements (+ the router Links) of a hook-free view's tree (components are not expanded): its handlers
type El = ReactElement<Record<string, unknown> & { children?: ReactNode }>;
function hosts(node: ReactNode, out: El[] = []): El[] {
  if (Array.isArray(node)) node.forEach((n) => hosts(n as ReactNode, out));
  else if (isValidElement(node)) {
    const el = node as El;
    if (typeof el.type === "string" || el.type === Link) out.push(el);
    hosts(el.props.children, out);
  }
  return out;
}
const view = (p: Omit<Props, "at">) => hosts(WaitingView({ ...p, at: AT }));
const byAttr = (els: El[], k: string, v: unknown) => els.filter((e) => e.props[k] === v);

describe("counts by kind", () => {
  const g = byKind(data);
  it("ask + review = the total (the dock badge); every waiting card is in exactly one of them", () => {
    expect([g.ask.count, g.review.count]).toEqual([2, 2]);
    expect(g.ask.count + g.review.count).toBe(data.total);
    const ids = [...g.ask.rows, ...g.review.rows].map((r) => r.card.id).sort((a, b) => a - b);
    expect(ids).toEqual(data.projects.flatMap((p) => p.cards.map((c) => c.id)).sort((a, b) => a - b));
  });
  it("external = blocked_external + CI-held cards, never counted in the total", () => {
    expect(g.external.count).toBe(2);
    expect(g.external.rows.map((r) => [r.card.id, r.slug])).toEqual([
      [8, "acme/widgets"],
      [9, "gadgets"],
    ]);
    expect(g.ask.count + g.review.count + g.external.count).not.toBe(data.total);
  });
  // an approved gate card its agent carries on (Awaiting merge after the final Approve) is no review
  it("approved = gate cards the operator approved that their agent carries on, never counted in the total", () => {
    expect(g.approved.count).toBe(2);
    expect(g.approved.rows.map((r) => r.card.id)).toEqual([463, 464]);
    expect(g.ask.count + g.review.count).toBe(data.total);
    expect([463, 464].some((id) => g.review.rows.some((r) => r.card.id === id))).toBe(false);
  });
  it("a non-ask, non-gate waiting card still counts (to review), so the segments add up", () => {
    const w = { ...data, total: 1, projects: [{ slug: "x", icon: null, count: 1, cards: [card(1, "some_col")] }] };
    expect([byKind(w).ask.count, byKind(w).review.count]).toEqual([0, 1]);
  });
  it("rows oldest first within each kind, an unknown time last (then by id)", () => {
    const w: Waiting = {
      ...empty,
      total: 4,
      projects: [
        {
          slug: "p",
          icon: null,
          count: 2,
          cards: [card(1, "ask"), card(2, "ask", { since: "2025-03-04T21:00:00Z" })],
        },
        {
          slug: "q",
          icon: null,
          count: 2,
          cards: [card(3, "ask", { since: "2025-03-04T10:00:00Z" }), card(0, "ask")],
        },
      ],
      held: [
        {
          slug: "p",
          icon: null,
          count: 2,
          cards: [card(5, "held"), card(6, "held", { since: "2025-03-01T00:00:00Z" })],
        },
      ],
      external: [{ slug: "q", icon: null, count: 1, cards: [card(4, "external", { since: "2025-03-02T00:00:00Z" })] }],
    };
    const g = byKind(w);
    expect(g.ask.rows.map((r) => r.card.id)).toEqual([3, 2, 0, 1]);
    expect(g.external.rows.map((r) => r.card.id)).toEqual([6, 4, 5]); // a held card's hand-off time; none → last
    const h = render({ data: w, error: null, open: true, kind: "external" });
    expect(h.indexOf("#6<")).toBeLessThan(h.indexOf("#4<"));
    expect(h).toMatch(/#5<\/span><span class="ww-title">card 5<\/span><span class="ww-age">—</);
  });
  it("each kind's projects, the most cards first, then by slug", () => {
    expect(g.ask.projects.map((p) => [p.slug, p.count])).toEqual([["gadgets", 2]]);
    expect(g.review.projects.map((p) => [p.slug, p.count])).toEqual([
      ["acme/widgets", 1],
      ["gadgets", 1],
    ]);
    expect(segmentLabel(g.review)).toBe("2 to review · acme/widgets, gadgets");
    expect(segmentLabel(byKind(empty).ask)).toBe("0 to answer");
  });
  it("links to the card on its board; ages, unknown stays unknown", () => {
    expect(cardHref("acme/widgets", 7)).toBe("/projects/acme/widgets?tab=board&card=7");
    expect(age("2025-03-04T21:53:00Z", AT)).toBe("7m");
    expect(age(null, AT)).toBe("—");
  });
});

describe("the plate", () => {
  it("one segment per kind, most important first: answer, review, external, approved; glyph + count + label", () => {
    const h = render({ data, error: null, open: false });
    const at = KINDS.map((k) => h.indexOf(`class="ww-seg ww-seg-${k}"`));
    expect(at.every((i) => i >= 0)).toBe(true);
    expect([...at].sort((a, b) => a - b)).toEqual(at);
    expect(h).toContain('aria-label="2 to answer · gadgets"');
    expect(h).toContain('<span class="ww-num">2</span><span class="ww-lab">to answer</span>');
    expect(h).toContain('aria-label="2 external · acme/widgets, gadgets"');
    expect(h).toContain('aria-label="2 approved · gadgets"');
    expect(h).toContain('src="/api/icons/gadgets?v=1"'); // the avatar stack
    expect(h).not.toContain("ww-panel");
    expect(h).not.toContain("aria-controls"); // nothing to control while closed
  });
  it("a kind with no cards has no segment", () => {
    const w = { ...data, total: 2, projects: [data.projects[0]!], held: [], external: [], approved: [] };
    const h = render({
      data: { ...w, projects: [{ ...w.projects[0]!, cards: w.projects[0]!.cards.slice(0, 2) }] },
      error: null,
      open: false,
    });
    expect(h).toContain("ww-seg-ask");
    expect(h).not.toContain("ww-seg-review");
    expect(h).not.toContain("ww-seg-external");
    expect(h).not.toContain("ww-seg-approved");
  });
  it("more than 3 projects: 3 avatars + '+N' (2 + '+N' under 600 px), never more", () => {
    const many: Waiting = {
      ...empty,
      total: 5,
      projects: ["a", "b", "c", "d", "e"].map((s, i) => ({
        slug: s,
        icon: null,
        count: 1,
        cards: [card(i + 1, "ask")],
      })),
    };
    const h = render({ data: many, error: null, open: false });
    expect(h.match(/class="picon/g)).toHaveLength(3);
    expect(h.match(/class="ww-av ww-av-wide"/g)).toHaveLength(1); // the third: hidden under 600 px
    expect(h).toContain('<span class="ww-more ww-more-wide">+2</span>');
    expect(h).toContain('<span class="ww-more ww-more-narrow">+3</span>');
  });
  it("zero: an explicit '0 waiting for you'; external still shown, never counted", () => {
    const z = render({ data: empty, error: null, open: true });
    expect(z).toContain("0 waiting for you");
    expect(z).toContain('class="ww-plate ww-zero"');
    expect(z).not.toContain("ww-seg");
    expect(z).not.toContain("ww-panel");
    const ze = render({ data: { ...empty, external: data.external }, error: null, open: false });
    expect(ze).toContain("0 waiting for you");
    expect(ze).toContain('aria-label="1 external · gadgets"');
  });
  it("loading: says so, no number", () => {
    const h = render({ data: null, error: null, open: true });
    expect(h).toContain('class="ww-plate ww-loading"');
    expect(h).toContain("loading…");
    expect(h).not.toMatch(/ww-num|ww-seg|ww-panel/);
  });
  it("error: the flag on the strip — never 0, never the last count, even with data kept", () => {
    const h = render({ data, error: "HTTP 503", open: false });
    expect(h).toContain("live · error");
    expect(h).toContain("HTTP 503");
    expect(h).not.toMatch(/ww-num|ww-seg|ww-panel|0 waiting/);
  });
  it("error with the sheet open: one 'read failed: <reason>' row, no tabs, no rows, no counts", () => {
    const h = render({ data, error: "HTTP 503", open: true, kind: "ask" });
    expect(h).toContain('<p class="ww-failed" role="alert">read failed: HTTP 503</p>');
    expect(h).not.toMatch(/ww-tab|ww-row|ww-num|#42/);
  });
});

describe("the sheet", () => {
  it("a segment's click opens its kind: onSegment(kind)", () => {
    const onSegment = vi.fn();
    const els = view({ data, error: null, open: false, onSegment });
    for (const k of KINDS) {
      const seg = byAttr(els, "data-kind", k).find((e) => e.type === "button")!;
      (seg.props.onClick as () => void)();
      expect(onSegment).toHaveBeenLastCalledWith(k);
    }
  });
  it("an avatar is inside its segment's button (no handler of its own): its click is the segment's", () => {
    const h = render({ data, error: null, open: false });
    expect(h).toMatch(
      /<button[^>]*class="ww-seg ww-seg-ask"[^>]*>(?:(?!<\/button>).)*class="ww-stack" aria-hidden="true"/,
    );
    const els = view({ data, error: null, open: false });
    expect(els.filter((e) => e.props.className === "ww-av").every((e) => e.props.onClick === undefined)).toBe(true);
  });
  it("a row links to the card's board dialog and closes the sheet (onRow)", () => {
    const onRow = vi.fn();
    const els = view({ data, error: null, open: true, kind: "ask", onRow });
    const links = els.filter((e) => e.type === Link);
    expect(links.map((l) => l.props.to)).toEqual([cardHref("gadgets", 42), cardHref("gadgets", 43)]);
    (links[0]!.props.onClick as () => void)();
    expect(onRow).toHaveBeenCalledTimes(1);
  });
  it("open on a kind: that tab selected, only its rows, each with its project; the segment says expanded", () => {
    const h = render({ data, error: null, open: true, kind: "review" });
    expect(h).toMatch(/class="ww-seg ww-seg-review"[^>]*aria-expanded="true"/);
    expect(h).toMatch(/class="ww-seg ww-seg-ask"[^>]*aria-expanded="false"/);
    expect(h).toMatch(/id="ww-tab-review"[^>]*aria-selected="true"[^>]*tabindex="0"/);
    expect(h).toMatch(/id="ww-tab-ask"[^>]*aria-selected="false"[^>]*tabindex="-1"/);
    expect(h).toContain('role="tabpanel" id="ww-list" aria-labelledby="ww-tab-review"');
    expect(h).toContain("#41");
    expect(h).toContain("#7<");
    expect(h).not.toContain("#42");
    expect(h).toContain('title="acme/widgets"'); // the row's project
    expect(h).toContain("open the preview");
    expect(h).toContain('href="/projects/acme/widgets?tab=board&amp;card=7"');
  });
  it("tabs carry every kind's count, zeros included", () => {
    const h = render({ data, error: null, open: true, kind: "ask" });
    expect(h).toMatch(/id="ww-tab-ask".*?<span class="ww-tab-n">2<\/span> <span class="ww-tab-lab">to answer/);
    expect(h).toMatch(/id="ww-tab-external".*?<span class="ww-tab-n">2<\/span> <span class="ww-tab-lab">external/);
    expect(h).toMatch(/id="ww-tab-approved".*?aria-label="2 approved"/);
  });
  it("ask rows: the question, the owner agent's live state and what blocks it", () => {
    const h = render({ data, error: null, open: true, kind: "ask", agents: { data: agentsData, error: null } });
    expect(h).toContain("Ship A or B?");
    expect(h).toContain("Widget &lt;b&gt;");
    expect(h).toContain('class="ww-agent ag-blocked"');
    expect(h).toContain("Allow git push?");
    expect(h).toContain("tl_gone · not running");
    expect(h).toContain("7m");
  });
  it("external rows: why each waits (blocked reason, CI hold)", () => {
    const h = render({ data, error: null, open: true, kind: "external" });
    expect(h).toContain("runner offline");
    expect(h).toContain("held: CI pending");
    expect(h).not.toContain("check the PR"); // a held gate card's handoff text is not why it waits
    expect(h).toContain('class="ww-row ww-k-external"');
  });
  it("approved rows: who carries it on and to where — merging on a final step, the next column otherwise", () => {
    const h = render({ data, error: null, open: true, kind: "approved" });
    expect(h).toContain("tl_lead merging");
    expect(h).toContain("w_2 → Deploy check");
    expect(h).toContain('class="ww-row ww-k-approved"');
    expect(h).toContain("Awaiting merge");
  });
  it("an approved row without its next step is a server bug: it throws, never a guessed line", () => {
    expect(() => approvedLine(card(1, "approved"))).toThrow(/: approved row without its agent's next step$/);
  });
  it("an approved card nobody owns waits for you (to review) and says why: approved · no agent", () => {
    const orphan = card(5, "review", { approved: "2025-03-04T21:00:00Z", approved_by: "op" });
    const w = { ...empty, total: 1, projects: [{ slug: "x", icon: null, count: 1, cards: [orphan] }] };
    const h = render({ data: w, error: null, open: true, kind: "review" });
    expect(h).toContain("approved · no agent");
  });
  it("a tab whose count dropped to 0 says so instead of an empty list", () => {
    const w = { ...data, held: [], external: [] };
    const h = render({ data: w, error: null, open: true, kind: "external" });
    expect(h).toContain("Nothing external");
  });
  it("agents unreachable: the error on the row, never a guessed state", () => {
    const h = render({ data, error: null, open: true, kind: "ask", agents: { data: agentsData, error: "HTTP 503" } });
    expect(h).toContain("tl_lead · agents: HTTP 503");
  });
});

describe("the open sheet across reads", () => {
  it("a good read with a segment: the list · a failed read: the error row · nothing to show: closed", () => {
    expect(sheetMode(data, null)).toBe("list");
    expect(sheetMode(data, "HTTP 503")).toBe("error");
    expect(sheetMode(null, null)).toBeNull();
    expect(sheetMode(empty, null)).toBeNull(); // every count at 0 → the widget closes it
    expect(sheetMode({ ...empty, external: data.external }, null)).toBe("list"); // external alone still shows
  });
  it("open → zero: no sheet, no segment says expanded; open → error → good read: the list again", () => {
    const z = render({ data: empty, error: null, open: true });
    expect(z).not.toMatch(/ww-panel|aria-expanded="true"/);
    expect(render({ data, error: "x", open: true })).toContain("read failed");
    expect(render({ data, error: null, open: true, kind: "ask" })).toContain('id="ww-list"');
  });
  const env = (swallow = true) => {
    const doc = new EventTarget();
    const timers: (() => void)[] = [];
    const win = Object.assign(new EventTarget(), {
      setTimeout: (f: () => void) => {
        timers.push(f);
        return 0;
      },
    });
    const close = vi.fn();
    const onEscape = vi.fn();
    const inner = {};
    const stop = sheetListeners(doc, win, (t) => t === inner, close, onEscape, swallow);
    return { doc, win, timers, close, onEscape, inner, stop };
  };
  const ev = (type: string, extra: object = {}) => Object.assign(new Event(type, { cancelable: true }), extra);
  it("Escape closes and hands focus back (onEscape); other keys do nothing", () => {
    const e = env();
    e.doc.dispatchEvent(ev("keydown", { key: "Enter" }));
    expect(e.close).not.toHaveBeenCalled();
    e.doc.dispatchEvent(ev("keydown", { key: "Escape" }));
    expect([e.close.mock.calls.length, e.onEscape.mock.calls.length]).toEqual([1, 1]);
  });
  it("a press outside closes and swallows the click that follows; a press inside does not", () => {
    const e = env();
    const inside = new Event("pointerdown");
    Object.defineProperty(inside, "target", { value: e.inner });
    e.doc.dispatchEvent(inside);
    expect(e.close).not.toHaveBeenCalled();
    e.doc.dispatchEvent(ev("pointerdown"));
    expect(e.close).toHaveBeenCalledTimes(1);
    const click = ev("click");
    e.win.dispatchEvent(click);
    expect(click.defaultPrevented).toBe(true);
    const next = ev("click");
    e.win.dispatchEvent(next);
    expect(next.defaultPrevented).toBe(false); // once
  });
  it("the read-failed sheet (swallow off): an outside press closes it and the page's click goes through", () => {
    const e = env(false);
    e.doc.dispatchEvent(ev("pointerdown"));
    expect(e.close).toHaveBeenCalledTimes(1);
    const click = ev("click");
    e.win.dispatchEvent(click);
    expect(click.defaultPrevented).toBe(false);
    expect(e.timers).toHaveLength(0);
  });
  it("the cleanup removes the listeners", () => {
    const e = env();
    e.stop();
    e.doc.dispatchEvent(ev("keydown", { key: "Escape" }));
    e.doc.dispatchEvent(ev("pointerdown"));
    expect(e.close).not.toHaveBeenCalled();
  });
});

describe("keyboard and focus", () => {
  it("arrow keys: ←/→ wrap, Home/End jump, other keys are not ours", () => {
    expect(nextKind("ask", "ArrowRight")).toBe("review");
    expect(nextKind("external", "ArrowRight")).toBe("approved");
    expect(nextKind("approved", "ArrowRight")).toBe("ask");
    expect(nextKind("ask", "ArrowLeft")).toBe("approved");
    expect(nextKind("review", "Home")).toBe("ask");
    expect(nextKind("ask", "End")).toBe("approved");
    expect(nextKind("ask", "Enter")).toBeNull();
  });
  it("a tab's arrow key selects the next tab and moves focus to it", () => {
    const onTab = vi.fn();
    const els = view({ data, error: null, open: true, kind: "ask", onTab });
    const tab = els.find((e) => e.props.id === "ww-tab-ask")!;
    const focus = vi.fn();
    const preventDefault = vi.fn();
    const ev = {
      key: "ArrowRight",
      preventDefault,
      currentTarget: {
        parentElement: { querySelector: (q: string) => (q === '[data-kind="review"]' ? { focus } : null) },
      },
    };
    (tab.props.onKeyDown as (e: typeof ev) => void)(ev);
    expect(onTab).toHaveBeenCalledWith("review");
    expect(preventDefault).toHaveBeenCalled();
    expect(focus).toHaveBeenCalled();
    const tabOnly = vi.fn();
    (tab.props.onKeyDown as (e: object) => void)({ ...ev, key: "Tab", preventDefault: tabOnly });
    expect(tabOnly).not.toHaveBeenCalled(); // Tab leaves the tab list as usual
  });
  it("↑/↓ between rows (no wrap), Home/End jump; other keys are not ours", () => {
    expect(nextRow(0, 3, "ArrowDown")).toBe(1);
    expect(nextRow(2, 3, "ArrowDown")).toBe(2);
    expect(nextRow(0, 3, "ArrowUp")).toBe(0);
    expect(nextRow(-1, 3, "ArrowUp")).toBe(2);
    expect(nextRow(1, 3, "End")).toBe(2);
    expect(nextRow(1, 3, "Enter")).toBeNull(); // Enter follows the link
    expect(nextRow(0, 0, "ArrowDown")).toBeNull();
  });
  it("the list's ↓ moves focus to the next row's link", () => {
    const els = view({ data, error: null, open: true, kind: "ask" });
    const ul = els.find((e) => e.type === "ul")!;
    expect(ul.props.onKeyDown).toBe(rowKey);
    const links = [{ focus: vi.fn() }, { focus: vi.fn() }];
    const preventDefault = vi.fn();
    rowKey({ key: "ArrowDown", preventDefault, target: links[0], currentTarget: { querySelectorAll: () => links } });
    expect(links[1]!.focus).toHaveBeenCalled();
    expect(preventDefault).toHaveBeenCalled();
  });
  it("↓ on a tab goes into the rows", () => {
    const els = view({ data, error: null, open: true, kind: "ask" });
    const tab = els.find((e) => e.props.id === "ww-tab-ask")!;
    const focus = vi.fn();
    const preventDefault = vi.fn();
    const qs = vi.fn(() => ({ focus }));
    (tab.props.onKeyDown as (e: object) => void)({
      key: "ArrowDown",
      preventDefault,
      currentTarget: { closest: () => ({ querySelector: qs }) },
    });
    expect(qs).toHaveBeenCalledWith("#ww-list a");
    expect([focus.mock.calls.length, preventDefault.mock.calls.length]).toEqual([1, 1]);
  });
  it("a tab's click selects it", () => {
    const onTab = vi.fn();
    const els = view({ data, error: null, open: true, kind: "ask", onTab });
    (els.find((e) => e.props.id === "ww-tab-external")!.props.onClick as () => void)();
    expect(onTab).toHaveBeenCalledWith("external");
  });
  it("Escape returns focus to the segment of the kind shown, else the first segment still there", () => {
    const m = new Map<Kind, string>([
      ["review", "R"],
      ["external", "E"],
    ]);
    expect(escapeFocus(m, "external")).toBe("E");
    expect(escapeFocus(m, "ask")).toBe("R");
    expect(escapeFocus(new Map<Kind, string>(), "ask")).toBeUndefined();
  });
  it("every segment and tab is a real button (focusable, Enter/Space)", () => {
    const els = view({ data, error: null, open: true, kind: "ask" });
    const kinds = els.filter((e) => e.props["data-kind"]);
    expect(kinds).toHaveLength(8);
    expect(kinds.every((e) => e.type === "button" && e.props.type === "button")).toBe(true);
  });
});

// text contrast on the plate and on each segment's tint, in both skins (WCAG 2.x, ≥ 4.5:1)
describe("contrast", () => {
  const css = readFileSync(new URL("../styles/waiting.css", import.meta.url), "utf8");
  const skin = (name: string) => {
    const y = readFileSync(new URL(`../../../skins/${name}.yml`, import.meta.url), "utf8");
    return (t: string) => y.match(new RegExp(`"--${t}":\\s*"(#[0-9a-f]{6})"`))![1]!;
  };
  const block = (sel: string) => css.slice(css.indexOf(sel), css.indexOf("}", css.indexOf(sel)));
  const tok = (b: string, t: string) => b.match(new RegExp(`--${t}:\\s*([^;]+);`))?.[1]?.trim();
  const rgb = (h: string) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const lum = (h: string) => {
    const [r, g, b] = rgb(h).map((v) => {
      const c = v / 255;
      return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
  };
  const ratio = (a: string, b: string) => {
    const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
    return (x! + 0.05) / (y! + 0.05);
  };
  const mix = (a: string, pct: number, b: string) =>
    "#" +
    rgb(a)
      .map((v, i) => Math.round((v * pct + rgb(b)[i]! * (100 - pct)) / 100))
      .map((v) => v.toString(16).padStart(2, "0"))
      .join("");
  const light = block(".waiting-widget {");
  const dark = block(':root[data-skin="dark"] .waiting-widget {');
  const cases: [string, ReturnType<typeof skin>, string][] = [
    ["light", skin("light"), light],
    ["dark", skin("dark"), dark],
  ];
  // every tint of a kind in the stylesheet (segment, hover, row chip): color-mix(in srgb, var(--ww-f-<kind>) N%, plate)
  const tints = (kind: string) =>
    [
      ...css.matchAll(new RegExp(`color-mix\\(in srgb, var\\(--ww-f-${kind}\\) (\\d+)%, var\\(--ww-plate\\)\\)`, "g")),
    ].map((m) => Number(m[1]));
  it("finds the tints it measures (segment + hover + row chip per kind)", () => {
    expect(tints("ask").length).toBeGreaterThanOrEqual(3);
    expect(tints("review").length).toBeGreaterThanOrEqual(3);
  });
  it.each(cases)(
    "%s: ask / review on every tint and the selected tab, external and the notes on the plate",
    (_, s, b) => {
      // a value: a hex, var(--token) (the block's own --ww-*, else the skin's), or color-mix of two of those
      const val = (t: string): string => resolve(tok(b, t) ?? tok(light, t)!);
      const resolve = (v: string): string => {
        const m = v.match(/^color-mix\(in srgb, (var\(--[\w-]+\)) (\d+)%, (var\(--[\w-]+\))\)$/);
        if (m) return mix(resolve(m[1]!), Number(m[2]), resolve(m[3]!));
        const ref = v.match(/^var\(--([\w-]+)\)$/);
        if (!ref) return v;
        return ref[1]!.startsWith("ww-") ? val(ref[1]!) : s(ref[1]!);
      };
      const bg = val("ww-plate");
      for (const k of ["ask", "review"]) {
        for (const pct of tints(k))
          expect(ratio(val(`ww-t-${k}`), mix(val(`ww-f-${k}`), pct, bg)), `${k} ${pct}%`).toBeGreaterThanOrEqual(4.5);
        expect(ratio(val(`ww-t-${k}`), s("mat-thumb")), `${k} selected tab`).toBeGreaterThanOrEqual(4.5);
      }
      expect(ratio(val("ww-t-external"), bg)).toBeGreaterThanOrEqual(4.5);
      expect(ratio(val("ww-t-approved"), bg)).toBeGreaterThanOrEqual(4.5);
      expect(ratio(val("ww-t-approved"), s("mat-thumb")), "approved selected tab").toBeGreaterThanOrEqual(4.5);
      expect(ratio(s("ink-faint"), bg)).toBeGreaterThanOrEqual(4.5); // loading / zero
      expect(ratio(s("bad"), bg)).toBeGreaterThanOrEqual(4.5); // error flag
      expect(ratio(s("bad"), mix(s("bad"), 8, bg))).toBeGreaterThanOrEqual(4.5); // the "read failed" row
      for (const k of ["ask", "review"]) expect(tok(b, `ww-t-${k}`) ?? tok(light, `ww-t-${k}`)).toMatch(/var\(--/); // tokens, no hex
    },
  );
});

// the plate at 390 px (the narrow rule): the worst case — 3 segments, 2-digit counts, 4+ projects each (2 avatars +
// "+N") — fits the 358 px between the 16 px gutters; widths from waiting.css, a digit at 0.7 em (wider than Inter's)
describe("avatars in the stack", () => {
  const css = readFileSync(new URL("../styles/waiting.css", import.meta.url), "utf8");
  const many: Waiting = {
    ...empty,
    total: 3,
    projects: ["acme/payments-api", "docs-site", "infra"].map((s, i) => ({
      slug: s,
      icon: null,
      count: 1,
      cards: [card(i + 1, "ask")],
    })),
  };
  it("one initial per stacked monogram (an overlapped second letter would be cut); the sheet's rows keep both", () => {
    expect([monogram("acme/payments-api", 1), monogram("acme/payments-api")]).toEqual(["P", "PA"]);
    const closed = render({ data: many, error: null, open: false });
    const stack = closed.slice(closed.indexOf('class="ww-stack"'), closed.indexOf("</button>"));
    expect([...stack.matchAll(/class="picon mono"[^>]*>([^<]*)</g)].map((m) => m[1])).toEqual(["P", "D", "I"]);
    const open = render({ data: many, error: null, open: true, kind: "ask" });
    const rows = open.slice(open.indexOf('id="ww-list"'));
    expect([...rows.matchAll(/class="picon mono"[^>]*>([^<]*)</g)].map((m) => m[1])).toEqual(["PA", "DS", "I"]);
  });
  it("spacing: the overlap leaves the centred initial of every avatar visible", () => {
    const overlap = Number(css.match(/\.ww-stack > \* \+ \* \{\s*margin-left: -([\d.]+)px;/)![1]);
    const size = 18;
    const step = size - overlap; // the visible part of each avatar but the last
    const letter = 0.7 * Math.max(8, Math.round(size * 0.42)); // one capital at ProjectIcon's font size, generously
    expect(size / 2 + letter / 2).toBeLessThanOrEqual(step);
  });
  it("the agent line ellipsizes instead of clipping", () => {
    expect(css).toMatch(/\.ww-agent span \{[^}]*min-width: 0;[^}]*overflow: hidden;[^}]*text-overflow: ellipsis;/);
  });
});

describe("width at 390 px", () => {
  const css = readFileSync(new URL("../styles/waiting.css", import.meta.url), "utf8");
  const narrow = css.slice(css.indexOf("@media (max-width: 600px)"));
  const px = (src: string, sel: string, prop: string) => {
    const b = src.slice(src.indexOf(sel), src.indexOf("}", src.indexOf(sel)));
    return b.match(new RegExp(`${prop}:\\s*([\\d.]+)px`))?.[1];
  };
  it("ask + review × (padding + glyph + 2 digits + 2 avatars + '+N' + gaps) + external + approved (glyph + count) + the plate's padding and border ≤ 358", () => {
    const pad = Number(narrow.match(/\.ww-seg \{[^}]*padding: 0 ([\d.]+)px/)![1]);
    const gap = Number(px(narrow, ".ww-seg {", "gap"));
    const glyph = Number(px(css, ".ww-glyph {", "width"));
    const digits = 2 * 0.7 * Number(px(css, ".ww-num {", "font-size"));
    const more = Number(px(css, ".ww-more {", "min-width")) + 2 * 4; // its padding: 0 4px for "+NN"
    const stack = 18 + (18 - 5) + (more - 5); // two 18 px avatars and "+N", each overlapping 5 px
    const seg = 2 * pad + glyph + digits + stack + 2 * gap; // glyph · count · stack (the label is hidden)
    const small = 2 * pad + glyph + digits + gap; // external / approved: glyph · count (their stacks hidden)
    const plate = 2 * seg + 2 * small + 3 * 2 + 2 * 3 + 2 * 1; // 2 px between segments · 3 px padding · 1 px border
    expect(narrow).toMatch(
      /\.ww-lab,\s*\.ww-av-wide,\s*\.ww-more-wide,\s*\.ww-seg-external \.ww-stack,\s*\.ww-seg-approved \.ww-stack \{\s*display: none;/,
    );
    expect(plate).toBeLessThanOrEqual(390 - 32);
  });
  // 4 tabs in the sheet — QA saw the 4th clipped (1280 px) and off-screen (390 px)
  it("the sheet's 4 tabs shrink, never wrap or overflow; narrow: only the selected tab keeps its label", () => {
    expect(css).toMatch(/\.ww-tab \{\s*flex: 1 1 0;\s*min-width: 0;\s*white-space: nowrap;/);
    expect(narrow).toMatch(/\.ww-tab\[aria-selected="false"\] \.ww-tab-lab \{\s*display: none;/);
    // a label too long for its tab ellipsizes inside it: the row never grows past the sheet
    expect(css).toMatch(/\.ww-tab-lab \{\s*min-width: 0;\s*overflow: hidden;\s*text-overflow: ellipsis;/);
  });
});
