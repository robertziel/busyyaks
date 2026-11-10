// The "waiting for you" widget: counts, the hover panel, its links, the error state — rendered to markup.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { WaitingView, type AgentsView } from "../components/Waiting";
import type { AgentsData } from "../types";
import { age, bubbles, cardHref, pillTotal, ring, topCount, totals, type Waiting } from "./waiting";

const AT = Date.parse("2025-03-04T22:00:00Z") / 1000;
const data: Waiting = {
  waiting_columns: ["ask_col", "check_col"],
  launch_failures: [],
  total: 3,
  projects: [
    {
      slug: "gadgets",
      icon: "/api/icons/gadgets?v=1",
      count: 2,
      cards: [
        {
          id: 42,
          title: "Widget <b>",
          column: "ask_col",
          column_label: "Human input",
          kind: "ask",
          needs_operator: true,
          blocked: false,
          since: "2025-03-04T21:53:00Z",
          question_first_line: "Ship A or B?",
          owner_session: "tl_lead",
        },
        {
          id: 41,
          title: "Lost cards",
          column: "check_col",
          column_label: "Human Check",
          kind: "review",
          needs_operator: false,
          blocked: false,
          since: "2025-03-04T19:00:00Z",
          question_first_line: null,
          owner_session: "tl_gone",
        },
      ],
    },
    {
      slug: "acme/widgets",
      icon: null,
      count: 1,
      cards: [
        {
          id: 7,
          title: "Check",
          column: "check_col",
          column_label: "Human Check",
          kind: "review",
          needs_operator: false,
          blocked: false,
          since: null,
          question_first_line: null,
          owner_session: null,
        },
      ],
    },
  ],
};
const render = (p: {
  data: Waiting | null;
  error: string | null;
  open: boolean;
  focus?: string | null;
  agents?: AgentsView;
  fit?: number;
}) => renderToStaticMarkup(createElement(MemoryRouter, null, createElement(WaitingView, { ...p, at: AT })));
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

describe("waiting helpers", () => {
  it("counts", () => {
    expect(pillTotal(data)).toBe("3 waiting");
  });
  it("bubbles: importance then latest, left to right — the most important and newest on the right", () => {
    const card = (id: number, kind: string, since: string | null) => ({
      id,
      title: "t",
      column: kind,
      column_label: kind,
      kind,
      needs_operator: kind === "ask",
      blocked: kind === "blocked",
      since,
      question_first_line: null,
      owner_session: null,
    });
    const w: Waiting = {
      waiting_columns: [],
      launch_failures: [],
      total: 6,
      projects: [
        { slug: "a/ask-old", icon: null, count: 1, cards: [card(1, "ask", "2025-03-04T10:00:00Z")] },
        {
          slug: "b/review-new",
          icon: null,
          count: 2,
          cards: [card(2, "review", "2025-03-04T21:00:00Z"), card(3, "review", null)],
        },
        {
          slug: "c/ask-new",
          icon: null,
          count: 2,
          cards: [card(4, "review", "2025-03-04T23:00:00Z"), card(5, "ask", "2025-03-04T20:00:00Z")],
        },
        { slug: "d/review-unknown", icon: null, count: 1, cards: [card(6, "review", null)] },
      ],
    };
    const b = bubbles(w);
    expect(b.map((x) => x.slug)).toEqual(["d/review-unknown", "b/review-new", "a/ask-old", "c/ask-new"]);
    expect(b.map((x) => x.level)).toEqual(["review", "review", "ask", "ask"]);
    expect(b[3]).toMatchObject({
      name: "ask-new",
      count: 2,
      asks: 1,
      reviews: 1,
      title: "c/ask-new · 1 needs input · 1 to merge",
    });
  });
  it("ring: one segment per status sized by count, most important first, 2° gaps; a single status is a plain colour", () => {
    expect(ring({ asks: 1, reviews: 3, others: 0 })).toBe(
      "conic-gradient(var(--ww-c-ask) 0.00% 24.44%, transparent 24.44% 25.00%, var(--ww-c-review) 25.00% 99.44%, transparent 99.44% 100.00%)",
    );
    expect(ring({ asks: 0, reviews: 2, others: 0 })).toBe("var(--ww-c-review)");
    expect(ring({ asks: 0, reviews: 1, others: 1 })).toContain("var(--ww-c-other) 50.00% 99.44%");
    expect(ring({ asks: 0, reviews: 0, others: 0 })).toBe("var(--ww-c-other)");
    expect(totals(data)).toEqual({ asks: 1, reviews: 2, others: 0 });
  });
  it("ring: needs input never below 20 % of a mixed ring", () => {
    expect(ring({ asks: 1, reviews: 18, others: 0 })).toMatch(
      /^conic-gradient\(var\(--ww-c-ask\) 0.00% 19.44%, transparent 19.44% 20.00%, var\(--ww-c-review\) 20.00% /,
    );
  });
  it("badge: the top status's count", () => {
    expect(bubbles(data).map((b) => [b.slug, topCount(b)])).toEqual([
      ["acme/widgets", 1],
      ["gadgets", 1],
    ]);
  });
  it("links to the card on its board", () => {
    expect(cardHref("acme/widgets", 7)).toBe("/projects/acme/widgets?tab=board&card=7");
  });
  it("ages, unknown stays unknown", () => {
    expect(age("2025-03-04T21:53:00Z", AT)).toBe("7m");
    expect(age("2025-03-04T19:00:00Z", AT)).toBe("3h");
    expect(age(null, AT)).toBe("—");
  });
});

describe("WaitingView", () => {
  it("closed: the total and one round bubble per project (icon, count, level), no panel", () => {
    const h = render({ data, error: null, open: false });
    expect(h).toContain("3 waiting");
    expect(h).toContain('class="ww-chip ww-ask" aria-label="gadgets · 1 needs input · 1 to merge"');
    expect(h).toContain('class="ww-chip ww-review" aria-label="acme/widgets · 1 to merge"');
    expect(h.indexOf('aria-label="acme/widgets ·')).toBeLessThan(h.indexOf('aria-label="gadgets ·')); // needs input on the right
    expect(h).toContain('src="/api/icons/gadgets?v=1"');
    expect(h).toContain('aria-expanded="false"');
    expect(h).not.toContain('class="ww-panel"');
  });
  it("a clicked bubble: only that project's tickets, each with its owner agent's live state and what blocks it", () => {
    const h = render({ data, error: null, open: true, focus: "gadgets", agents: { data: agentsData, error: null } });
    expect(h).toContain("#42");
    expect(h).not.toContain("#7<");
    expect(h).toContain('class="ww-agent ag-blocked"');
    expect(h).toContain("tl_lead · blocked");
    expect(h).toContain("Allow git push?");
    expect(h).toContain("tl_gone · not running");
    expect(h).toMatch(/class="ww-chip ww-ask"[^>]*aria-expanded="true"/);
  });
  it("blocked on a card question: the reason is the sidebar's (card #N: question)", () => {
    const ad = {
      groups: [
        {
          label: "gadgets",
          slug: "gadgets",
          icon: null,
          state: "blocked",
          sessions: [
            session("tl_lead", "blocked", {
              asks: [{ id: 42, title: "Widget", question: "Ship A or B?", path: "/x" }],
            }),
          ],
        },
      ],
    } as unknown as AgentsData;
    const h = render({ data, error: null, open: true, focus: "gadgets", agents: { data: ad, error: null } });
    expect(h).toContain("card #42: Ship A or B?");
  });
  it("closed: no aria-controls pointing at a panel that is not there", () => {
    expect(render({ data, error: null, open: false })).not.toContain("aria-controls");
    expect(render({ data, error: null, open: true })).toContain('aria-controls="ww-panel"');
  });
  it("all: projects in the bubbles' order, most important first", () => {
    const h = render({ data, error: null, open: true });
    expect(h.indexOf("#42")).toBeLessThan(h.indexOf("#7<"));
  });
  it("too narrow: the least important bubbles fold into +N on the left, the most important stay", () => {
    const h = render({ data, error: null, open: false, fit: 1 });
    expect(h).toContain("+1");
    expect(h).toContain('aria-label="1 more projects: show all"');
    expect(h).toContain('class="ww-chip ww-ask"');
    expect(h).not.toContain('class="ww-chip ww-review"');
  });
  it("agents unreachable: the error on the row, never a guessed state", () => {
    const h = render({
      data,
      error: null,
      open: true,
      focus: "acme/widgets",
      agents: { data: null, error: "HTTP 503" },
    });
    expect(h).toContain("no agent"); // widgets' card has no owner session
    const t = render({
      data,
      error: null,
      open: true,
      focus: "gadgets",
      agents: { data: agentsData, error: "HTTP 503" },
    });
    expect(t).toContain("tl_lead · agents: HTTP 503");
  });
  it("open: the tickets grouped by project, Human input first, with column, age, question and link", () => {
    const h = render({ data, error: null, open: true });
    expect(h).toContain('aria-expanded="true"');
    expect(h.indexOf("#42")).toBeLessThan(h.indexOf("#41"));
    expect(h).toContain('href="/projects/gadgets?tab=board&amp;card=42"');
    expect(h).toContain('href="/projects/acme/widgets?tab=board&amp;card=7"');
    expect(h).toContain("Human input");
    expect(h).toContain('class="ww-row ww-k-ask"'); // the row asking you
    expect(h).toContain("7m");
    expect(h).toContain("Ship A or B?");
    expect(h).toContain("Widget &lt;b&gt;");
  });
  it("the total is a number circle coloured by the most important input", () => {
    const h = render({ data, error: null, open: false });
    expect(h).toContain('class="ww-total ww-t-ask"');
    expect(h).toContain('aria-label="3 waiting: show all"');
    expect(h).toMatch(
      /<span class="ww-face" style="--ww-ring:conic-gradient\(var\(--ww-c-ask\) 0.00% 32.78%[^"]*">3<\/span>/,
    );
    expect(h).toContain('<b class="ww-n"><span aria-hidden="true">?</span>1</b>'); // gadgets: 1 needs input, marked without colour
    expect(h).toContain('<span class="ww-tip" role="tooltip"><b>3 waiting</b>');
  });
  it("hover values: each bubble's tooltip has its counts per status in their colours and the newest age", () => {
    const h = render({ data, error: null, open: false });
    const tip = h.slice(h.indexOf("<b>gadgets</b>"), h.indexOf("</span></button>", h.indexOf("<b>gadgets</b>")));
    expect(tip).toContain('style="background:var(--ww-c-ask)"');
    expect(tip).toContain("<em>1</em> needs input");
    expect(tip).toContain("<em>1</em> to merge");
    expect(tip).toContain("newest 7m");
    expect(h).not.toMatch(/class="ww-chip[^"]*" title=/); // no native title doubling the tooltip
  });
  it("zero: a quiet 0 waiting, never gone, no panel even when open", () => {
    const h = render({
      data: { waiting_columns: [], total: 0, projects: [], launch_failures: [] },
      error: null,
      open: true,
    });
    expect(h).toContain("0 waiting");
    expect(h).toContain("ww-zero");
    expect(h).not.toContain('class="ww-panel"');
  });
  it("error: live · error with the reason, no numbers shown as current", () => {
    const h = render({ data, error: "HTTP 503", open: true });
    expect(h).toContain("live · error");
    expect(h).toContain("HTTP 503");
    expect(h).not.toContain("3 waiting");
    expect(h).not.toContain('class="ww-panel"');
  });
});
