import { describe, expect, it, vi } from "vitest";
import { readWaiting, setAppBadge } from "./appBadge";

const nav = () => ({
  setAppBadge: vi.fn(() => Promise.resolve()),
  clearAppBadge: vi.fn(() => Promise.resolve()),
});

describe("setAppBadge", () => {
  it("puts the waiting total on the icon", () => {
    const n = nav();
    setAppBadge(3, n);
    expect(n.setAppBadge).toHaveBeenCalledWith(3);
    expect(n.clearAppBadge).not.toHaveBeenCalled();
  });

  it("clears the badge at zero", () => {
    const n = nav();
    setAppBadge(0, n);
    expect(n.clearAppBadge).toHaveBeenCalled();
    expect(n.setAppBadge).not.toHaveBeenCalled();
  });

  it("an unknown count (a failed read) shows the flag badge: no number, never 0, never the last count", () => {
    const n = nav();
    setAppBadge(4, n);
    setAppBadge(null, n);
    expect(n.setAppBadge).toHaveBeenLastCalledWith();
    expect(n.clearAppBadge).not.toHaveBeenCalled();
  });

  it("does nothing where the Badging API does not exist", () => {
    expect(() => setAppBadge(2, {})).not.toThrow();
  });

  it("reports a refused badge instead of an unhandled rejection", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    setAppBadge(1, { setAppBadge: () => Promise.reject(new Error("no")), clearAppBadge: () => Promise.resolve() });
    await new Promise((r) => setTimeout(r, 0));
    expect(warn).toHaveBeenCalledWith("app badge not set:", expect.any(Error));
    warn.mockRestore();
  });
});

describe("readWaiting (the widget's /api/waiting read)", () => {
  it("a good read hands the data on and badges its total", async () => {
    const n = nav();
    const onData = vi.fn();
    const onError = vi.fn();
    expect(await readWaiting(() => Promise.resolve({ total: 5 }), onData, onError, n)).toBeNull();
    expect(onData).toHaveBeenCalledWith({ total: 5 });
    expect(n.setAppBadge).toHaveBeenCalledWith(5);
    expect(onError).not.toHaveBeenCalled();
  });

  it("a failed read reports the error and marks the badge unknown, never 0", async () => {
    const n = nav();
    const onData = vi.fn();
    const onError = vi.fn();
    // the outcome is the caller's too — the live poll asks again after a failed read
    expect(await readWaiting(() => Promise.reject(new Error("502 bad gateway")), onData, onError, n)).toBe(
      "502 bad gateway",
    );
    expect(onError).toHaveBeenCalledWith("502 bad gateway");
    expect(onData).not.toHaveBeenCalled();
    expect(n.setAppBadge).toHaveBeenCalledWith();
    expect(n.clearAppBadge).not.toHaveBeenCalled();
  });
});
