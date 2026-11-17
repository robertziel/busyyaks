// The compact row as rendered (Row in Agents.tsx): its lines in order, the launcher only off the norm, the card tags
// whole, the third line only for a row that waits for you. Static markup — the layout itself is agentRowCss.test.ts.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { AgentSession } from "../types";
import { Row } from "./Agents";

const card = (id: number, column_label: string, gate_hold: string | null = null) => ({
  id,
  slug: "p",
  title: "t",
  column_label,
  column_type: null,
  gate_hold,
  blocked_external: null,
  approved_carried_on: false,
  path: "/",
});

const s = (extra: Partial<AgentSession> = {}) =>
  ({
    name: "proj_worker",
    state: "working",
    state_by: null,
    unread: false,
    attached: false,
    activity: null,
    cards_known: true,
    cards: [],
    cards_finished: 0,
    asks: [],
    reviews: [],
    dialogs: [],
    waiting_for: [],
    subagents: 0,
    engines: ["Claude"],
    title: null,
    cwd: null,
    phase: "thinking",
    ...extra,
  }) as AgentSession;

const html = (session: AgentSession, norm: string | null = "Claude") =>
  renderToStaticMarkup(createElement(Row, { s: session, norm }));
// where each line starts in the markup (-1 = not drawn)
const at = (markup: string): [number, number, number] => {
  const [l1, l2, l3] = ["ag-l1", "ag-l2", "ag-cards"].map((c) => markup.indexOf(`<span class="${c}">`));
  return [l1!, l2!, l3!];
};
// the text of the markup from `from` on, tags dropped
const text = (markup: string, from: number) => markup.slice(from).replace(/<[^>]+>/g, "");

describe("Row", () => {
  it("line 1 = the name; line 2 = the state word, the cut detail, then the card tag drawn whole; no third line", () => {
    const out = html(s({ cards: [card(13, "Human Check", "pending")] }));
    const [l1, l2, l3] = at(out);
    expect(l1).toBeGreaterThan(-1);
    expect(l2).toBeGreaterThan(l1);
    expect(l3).toBe(-1);
    expect(text(out, l1)).toMatch(/^proj_worker/);
    expect(text(out, l2)).toBe("thinking#13 Human CheckCI wait");
    expect(out).toContain('<span class="ag-flag" title="#13 waiting for CI">CI wait</span>');
  });
  it("the launcher is named only when it is not the norm; subagents as a figure", () => {
    expect(html(s())).not.toContain("ag-eng");
    const off = html(s({ engines: ["Hermes"], subagents: 3 }));
    expect(off).toContain('<span class="ag-eng">Hermes</span>');
    expect(off).toContain('title="3 subagents running">3 sub</span>');
  });
  it("a row that waits for you: what it waits for, and its other cards on a third line", () => {
    const ask = { id: 11, slug: "p", title: "Compact rows", question: "A or B?", options: [], path: "/" };
    const out = html(s({ state: "blocked", asks: [ask], cards: [card(11, "In progress"), card(12, "QA")] }));
    const [, l2, l3] = at(out);
    expect(l3).toBeGreaterThan(l2);
    expect(text(out, l2)).toMatch(/^needs inputcard #11: A or B\?/);
    expect(text(out, l3)).toBe("#12 QA");
  });
});
