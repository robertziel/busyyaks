// revalidate (the useResource cache's read, and so a route's reload) resolves to its outcome — null when the data
// landed, the ApiError when it failed — so a live poll can ask a failed refresh again. It never rejects.
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, revalidate } from "./api";

const answer = (status: number, body: unknown) =>
  vi.fn(() => Promise.resolve(new Response(JSON.stringify(body), { status })));

describe("revalidate", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("resolves to null when the data landed", async () => {
    vi.stubGlobal("fetch", answer(200, { n: 1 }));
    expect(await revalidate("/api/revalidate-ok")).toBeNull();
  });

  it("resolves to the ApiError when the read failed, never rejects", async () => {
    vi.stubGlobal("fetch", answer(502, { error: "502 Bad Gateway" }));
    const out = await revalidate("/api/revalidate-down");
    expect(out).toBeInstanceOf(ApiError);
    expect(out?.message).toBe("502 Bad Gateway");
    expect(out?.status).toBe(502);
  });

  it("a read already in flight answers with that read's outcome", async () => {
    vi.stubGlobal("fetch", answer(503, { error: "down" }));
    const [a, b] = [revalidate("/api/revalidate-same"), revalidate("/api/revalidate-same")];
    expect((await a)?.message).toBe("down");
    expect((await b)?.message).toBe("down");
  });
});
