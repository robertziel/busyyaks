import { describe, expect, it } from "vitest";
import { markOf, placeMark, rateColour, spark } from "./sparkline";

describe("spark", () => {
  it("draws one run for consecutive samples, axis to the peak", () => {
    const s = spark([0, 5, 10]);
    expect(s.peak).toBe(10);
    expect(s.top).toBe(10);
    expect(s.line).toBe("M0.00 23.00L50.00 12.00L100.00 1.00");
    expect(s.lone).toBe("");
    expect(s.samples).toBe("111");
  });

  it("breaks the line at a gap and draws a lone sample as a dot — never a zero", () => {
    const s = spark([3, null, 6, null, 2, 4]);
    expect(s.samples).toBe("101011");
    expect(s.lone).toContain("M40.00");
    expect(s.lone).toContain("M0.00");
    expect(s.line.match(/M/g)?.length).toBe(1); // only 2,4 form a run
    expect(s.ys[1]).toBeNull();
  });

  it("all gaps draw nothing; all zeros sit on the base with a ceiling of 1", () => {
    expect(spark([null, null]).line).toBe("");
    const z = spark([0, 0, 0]);
    expect(z.top).toBe(1);
    expect(z.line).toBe("M0.00 23.00L50.00 23.00L100.00 23.00");
    expect(markOf(z)).toBeNull();
  });

  it("gradient: one stop per change, a gap carries the colour before it", () => {
    const s = spark([2, null, 4]);
    expect(s.stops.map((x) => x.t)).toEqual([0.5, 0.5, 1]);
    const flat = spark([1, 1, 1, 1]);
    expect(flat.stops.map((x) => x.offset)).toEqual([0, 1]);
  });
});

describe("markOf / placeMark", () => {
  it("names the peak at its level", () => {
    expect(markOf(spark([1, 262, 4]))).toEqual({ text: "max 262", level: 0 });
  });

  it("keeps the label off the line: peak at the trailing end → leading end", () => {
    const s = spark([0, 0, 0, 0, 10]);
    const spot = placeMark(s.ys, 0, 200, 44, 40, 11);
    expect(spot).not.toBeNull();
    expect(spot!.trailing).toBe(false);
  });

  it("no room → not drawn", () => {
    expect(placeMark([0, 0], 0, 200, 8, 40, 11)).toBeNull();
    expect(placeMark([0], 0, 200, 44, 40, 11)).toBeNull();
  });
});

describe("rateColour", () => {
  it("rest → mid → high, clamped", () => {
    expect(rateColour(0)).toBe("color-mix(in oklch, var(--rate-rest), var(--rate-mid) 0%)");
    expect(rateColour(0.5)).toBe("color-mix(in oklch, var(--rate-rest), var(--rate-mid) 100%)");
    expect(rateColour(2)).toBe("color-mix(in oklch, var(--rate-mid), var(--rate-high) 100%)");
  });
});
