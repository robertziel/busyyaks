// card 672: the mascot scene per failure, the down banner's words, and the generated scenes' contract
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { Mascot } from "../components/Mascot";
import { PageBoundary, PageCrashed } from "../components/PageBoundary";
import { YAK_MASCOTS } from "../components/yakMascots";
import { downText, sceneFor } from "./mascot";

describe("sceneFor", () => {
  it("404 = lost, 0 (never reached the server) = offline, any other answer = broken", () => {
    expect(sceneFor(404)).toBe("lost");
    expect(sceneFor(0)).toBe("offline");
    for (const s of [400, 401, 403, 409, 422, 500, 503, 504]) expect(sceneFor(s)).toBe("broken");
  });
});

describe("downText", () => {
  it("names the device when the browser is offline, the server otherwise, and the retry period", () => {
    expect(downText(false, 3)).toEqual({
      title: "No internet",
      detail: "This device is offline — this page is not live. Retrying every 3 s.",
    });
    expect(downText(true, 3)).toEqual({
      title: "busyyaks is not answering",
      detail: "This page is not live. Retrying every 3 s.",
    });
  });
});

describe("YAK_MASCOTS", () => {
  it("each scene: skin colours only (currentColor + --accent), no ids, hidden from screen readers, still under reduced motion", () => {
    expect(Object.keys(YAK_MASCOTS)).toEqual(["lost", "broken", "offline"]);
    for (const svg of Object.values(YAK_MASCOTS)) {
      expect(svg).toMatch(/^<svg [^>]*aria-hidden="true"/);
      expect(svg).not.toMatch(/\bid="/);
      expect(svg.match(/#[0-9a-fA-F]{3,8}\b/g)).toBeNull();
      expect(svg).toContain("var(--accent)");
      expect(svg).toContain("prefers-reduced-motion:reduce");
    }
  });
});

describe("Mascot", () => {
  it("a page state is a heading, a smaller one a strong; the art is hidden", () => {
    const page = renderToStaticMarkup(createElement(Mascot, { scene: "lost", title: "404" }, "no page"));
    expect(page).toMatch(
      /^<div class="mascot mascot-page" data-scene="lost"><span class="mascot-art" aria-hidden="true"><svg/,
    );
    expect(page).toContain('<h1 class="mascot-title">404</h1>no page');
    const card = renderToStaticMarkup(createElement(Mascot, { scene: "broken", title: "x", size: "card" }));
    expect(card).toContain('<strong class="mascot-title">x</strong>');
  });
});

describe("PageBoundary", () => {
  it("a throw becomes the error it shows, a non-Error thrown included", () => {
    expect(PageBoundary.getDerivedStateFromError(new TypeError("x is undefined")).error.message).toBe("x is undefined");
    expect(PageBoundary.getDerivedStateFromError("boom").error.message).toBe("boom");
  });
  it("moving to another path clears the crash; the same path keeps it", () => {
    const b = new PageBoundary({ path: "/b", children: null });
    const set: unknown[] = [];
    b.setState = (s: unknown) => void set.push(s);
    b.state = { error: new Error("x") };
    b.componentDidUpdate({ path: "/b" });
    expect(set).toEqual([]);
    b.componentDidUpdate({ path: "/a" });
    expect(set).toEqual([{ error: null }]);
    b.state = { error: null };
    b.componentDidUpdate({ path: "/c" });
    expect(set).toHaveLength(1);
  });
  it("the crashed page: broken yak, the error's message, Reload", () => {
    const html = renderToStaticMarkup(createElement(PageCrashed, { error: new Error("a <b> c") }));
    expect(html).toMatch(/^<div role="alert"><div class="mascot mascot-page" data-scene="broken">/);
    expect(html).toContain("<code>a &lt;b&gt; c</code>");
    expect(html).toContain(">Reload</button>");
  });
});

describe("ErrorState / RefreshError", () => {
  it("nothing to show: the yak card for the failure's scene; data still shown: one slim bar, no yak", async () => {
    const { ErrorState, RefreshError } = await import("../components/States");
    const { ApiError } = await import("../api");
    const card = renderToStaticMarkup(
      createElement(ErrorState, { error: new ApiError(404, "no report 9"), what: "report 9" }),
    );
    expect(card).toMatch(/^<div class="state error" role="alert"><div class="mascot mascot-card" data-scene="lost">/);
    expect(card).toContain("404 · no report 9");
    const bar = renderToStaticMarkup(createElement(RefreshError, { error: new ApiError(0, "network error") }));
    expect(bar).toMatch(/^<div class="flash bad" role="alert">/);
    expect(bar).toContain("refresh: network error");
    expect(bar).not.toContain("mascot");
  });
});
