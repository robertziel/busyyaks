import { describe, expect, it } from "vitest";
import type { ReportDigest } from "../types";
import { authorParts, digestCounters, figureChange } from "./report";

describe("authorParts", () => {
  it("splits the model detail off the name", () => {
    expect(authorParts("busyyaks-daily (sonnet + one sonnet agent per repo)")).toEqual({
      name: "busyyaks-daily",
      detail: "sonnet + one sonnet agent per repo",
    });
  });
  it("keeps a plain name", () => {
    expect(authorParts("claude")).toEqual({ name: "claude", detail: null });
    expect(authorParts("(odd)")).toEqual({ name: "(odd)", detail: null });
  });
});

describe("figureChange", () => {
  const f = (delta: string | null, good: "up" | "down" | null = null) => ({
    label: "x",
    value: "1",
    tone: "neutral" as const,
    delta,
    good,
  });
  it("is null without a prev", () => expect(figureChange(f(null))).toBeNull());
  it("colours by the good direction", () => {
    expect(figureChange(f("37", "up"))).toEqual({ dir: "up", feel: "good", text: "▲37" });
    expect(figureChange(f("4", "down"))).toEqual({ dir: "up", feel: "bad", text: "▲4" });
    expect(figureChange(f("-3", "down"))).toEqual({ dir: "down", feel: "good", text: "▼3" });
    expect(figureChange(f("0", "down"))).toEqual({ dir: "flat", feel: "", text: "=" });
    expect(figureChange(f("2"))).toEqual({ dir: "up", feel: "", text: "▲2" });
  });
});

describe("digestCounters", () => {
  const d: ReportDigest = {
    figures: [],
    headline: null,
    actions: { high: 2, med: 1, low: 0 },
    repos: 5,
    flags: 0,
    needs: 1,
    broken: 0,
  };
  it("lists non-zero counters, urgent first", () => {
    expect(digestCounters(d).map((c) => `${c.n} ${c.label}`)).toEqual(["1 need you", "2 high", "3 actions", "5 repos"]);
  });
  it("puts broken blocks first", () => {
    expect(digestCounters({ ...d, broken: 1 })[0]).toMatchObject({ key: "broken", tone: "bad", label: "broken block" });
  });
});
