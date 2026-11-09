import { describe, expect, it } from "vitest";
import { dayShort, dayTiles, total } from "../components/DailyStats";
import type { TileProps } from "../components/GraphTile";

const day = (prs: number | null) => ({ day: "2026-11-06", commits: 2, mine: 1, repos: 1, prs });

describe("DailyStats helpers", () => {
  it("names today and other days by weekday + date", () => {
    expect(dayShort("2026-11-06", "2026-11-06")).toBe("Today");
    expect(dayShort("2026-11-05", "2026-11-06")).toBe("Thu 05.11");
  });
  it("totals a column, unknown when any day is unknown", () => {
    expect(total([day(1), day(2)], "prs")).toBe(3);
    expect(total([day(1), day(null)], "prs")).toBeNull();
    expect(total([day(null)], "commits")).toBe(2);
  });
});

describe("dayTiles", () => {
  const stats = { repos: 9, active7: 4, commits_today: 5, dirty: 0, unpushed: 0, prs_today: null };
  const days = [
    { day: "2026-11-07", commits: 5, mine: 3, repos: 2, prs: null },
    { day: "2026-11-06", commits: 8, mine: 6, repos: 3, prs: 2 },
  ];
  it("today's figure over the window's series oldest first; unknown PRs a gap, never 0", () => {
    const [c, m, r, p] = dayTiles(days, "2026-11-07", stats) as [TileProps, TileProps, TileProps, TileProps];
    expect(c.value).toBe(5);
    expect(c.series).toEqual([8, 5]);
    expect(m.value).toBe(3);
    expect(r.value).toBe(2);
    expect(p.value).toBeNull();
    expect(p.series).toEqual([2, null]);
    expect(p.title).toBe("Fri 06.11 2 · Today —");
  });
});
