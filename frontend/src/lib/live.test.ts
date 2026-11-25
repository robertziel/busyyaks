// takeRev: a revision that changed counts as shown only once its refresh landed — a refresh that failed leaves the
// last shown revision, so the next poll asks again, and its error is the live state's (one failed refetch would keep
// a moved card in its old column under a green live mark). refreshed: a reload's outcome as that refresh.
import { describe, expect, it, vi } from "vitest";
import { refreshed, takeRev } from "./live";

describe("takeRev", () => {
  it("the first revision is the baseline: nothing refreshed", async () => {
    const change = vi.fn();
    expect(await takeRev(null, "r1", change)).toEqual({ shown: "r1", error: null });
    expect(change).not.toHaveBeenCalled();
  });

  it("the same revision: nothing refreshed", async () => {
    const change = vi.fn();
    expect(await takeRev("r1", "r1", change)).toEqual({ shown: "r1", error: null });
    expect(change).not.toHaveBeenCalled();
  });

  it("a new revision is shown once its refresh landed", async () => {
    const change = vi.fn(() => Promise.resolve());
    expect(await takeRev("r1", "r2", change)).toEqual({ shown: "r2", error: null });
    expect(change).toHaveBeenCalledOnce();
  });

  it("a refresh that failed keeps the last shown revision and says why", async () => {
    const change = vi.fn(() => Promise.reject(new Error("502 Bad Gateway")));
    expect(await takeRev("r1", "r2", change)).toEqual({ shown: "r1", error: "refresh failed: 502 Bad Gateway" });
  });

  it("asked again on the next poll until it lands", async () => {
    let fail = true;
    const change = vi.fn(() => (fail ? Promise.reject(new Error("down")) : Promise.resolve()));
    let { shown } = await takeRev("r1", "r2", change);
    ({ shown } = await takeRev(shown, "r2", change));
    expect(change).toHaveBeenCalledTimes(2);
    expect(shown).toBe("r1");
    fail = false;
    ({ shown } = await takeRev(shown, "r2", change));
    expect(shown).toBe("r2");
    await takeRev(shown, "r2", change);
    expect(change).toHaveBeenCalledTimes(3);
  });
});

describe("refreshed", () => {
  it("resolves when the reload's data landed", async () => {
    await expect(refreshed(() => Promise.resolve(null))()).resolves.toBeUndefined();
  });

  it("rejects with the reload's error", async () => {
    await expect(refreshed(() => Promise.resolve(new Error("502")))()).rejects.toThrow("502");
  });

  it("a message is an error too", async () => {
    await expect(refreshed(() => Promise.resolve("network error"))()).rejects.toThrow("network error");
  });
});
