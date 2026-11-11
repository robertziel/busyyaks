import { describe, expect, it } from "vitest";
import type { AgentSession } from "../types";
import { cardLine } from "./Agents";

const s = (extra: Partial<AgentSession>) =>
  ({ cards_known: true, cards: [], cards_finished: 0, asks: [], reviews: [], ...extra }) as AgentSession;
const c = (
  id: number,
  column_label: string,
  gate_hold: string | null = null,
  blocked_external: string | null = null,
) => ({
  id,
  slug: "p",
  title: "t",
  column_label,
  column_type: null,
  gate_hold,
  blocked_external,
  path: "/",
});

describe("cardLine", () => {
  it("open cards by column label, then how many are done", () => {
    expect(cardLine(s({ cards: [c(3, "In progress"), c(5, "Merged")], cards_finished: 2 }))).toBe(
      "#3 In progress · #5 Merged · +2 done",
    );
    expect(cardLine(s({ cards_finished: 3 }))).toBe("+3 done");
  });
  it("a gate card that cannot be approved now says it waits for CI", () => {
    expect(cardLine(s({ cards: [c(4, "Local: Human review", "PR #7: CI is still running")] }))).toBe(
      "#4 Local: Human review · waiting for CI",
    );
  });
  it("a card blocked on the world says so: it waits for no operator", () => {
    expect(cardLine(s({ cards: [c(12, "Public: Create PR", null, "waits for card #9")] }))).toBe(
      "#12 Public: Create PR · blocked externally",
    );
  });
  it("no cards is said; a card already on the why line is not repeated", () => {
    expect(cardLine(s({}))).toBe("no cards");
    expect(cardLine(s({ cards_known: false }))).toBe("not registered: cards unknown");
    const r = { id: 9, slug: "p", title: "t", pr_url: null, path: "/" };
    expect(cardLine(s({ cards: [c(9, "Human Check")], reviews: [r] }))).toBe("");
  });
});
