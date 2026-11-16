import { describe, expect, it, vi } from "vitest";
import { initialHealth, keepRemote, nextHealth, probe, remoteHost } from "./connection";

const store = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
};

describe("nextHealth", () => {
  it("one failed read is reconnecting, two in a row are down, one good read is connected again", () => {
    const one = nextHealth(initialHealth, false);
    expect(one.state).toBe("reconnecting");
    const two = nextHealth(one, false);
    expect(two.state).toBe("down");
    expect(nextHealth(two, false).state).toBe("down");
    expect(nextHealth(two, true)).toEqual(initialHealth);
  });
});

describe("keepRemote", () => {
  it("keeps the label at boot, so a redirect that drops the query (/hello) still shows it", () => {
    const s = store();
    keepRemote("?remote=myserver", s);
    expect(remoteHost("", s)).toBe("myserver");
  });
});

describe("remoteHost", () => {
  it("takes ?remote=<host> and keeps it for the window", () => {
    const s = store();
    expect(remoteHost("?remote=myserver", s)).toBe("myserver");
    expect(remoteHost("", s)).toBe("myserver");
  });

  it("this machine (nothing given or kept) is null", () => {
    expect(remoteHost("", store())).toBeNull();
    expect(remoteHost("", null)).toBeNull();
  });

  it("refuses anything that is not a host name", () => {
    const s = store();
    expect(remoteHost("?remote=%3Cb%3Ex", s)).toBeNull();
    expect(remoteHost("?remote=", s)).toBeNull();
    expect(remoteHost("", s)).toBeNull();
  });

  it("storage that throws still labels this page", () => {
    const bad = {
      getItem: () => {
        throw new Error("off");
      },
      setItem: () => {
        throw new Error("off");
      },
    };
    expect(remoteHost("?remote=srv", bad)).toBe("srv");
    expect(remoteHost("", bad)).toBeNull();
  });
});

describe("probe", () => {
  it("is true only for a 200 from /up", async () => {
    const ok = vi.fn(() => Promise.resolve(new Response("ok", { status: 200 })));
    expect(await probe(ok as unknown as typeof fetch)).toBe(true);
    expect(ok).toHaveBeenCalledWith("/up", expect.objectContaining({ cache: "no-store" }));
    const bad = () => Promise.resolve(new Response("", { status: 502 }));
    expect(await probe(bad as unknown as typeof fetch)).toBe(false);
    const down = () => Promise.reject(new TypeError("Failed to fetch"));
    expect(await probe(down as unknown as typeof fetch)).toBe(false);
  });
});
