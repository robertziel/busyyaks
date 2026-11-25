// @vitest-environment happy-dom
// The page side of the new-waiting alert, mounted for real: the hook in a React root, the title, the favicon, the
// theme-color meta, the focus / visibility / storage wiring and the unmount clear (lib/newWaiting.test.ts covers the
// decision itself).
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SEEN_KEY } from "./newWaiting";
import type { Waiting, WaitingCard } from "./waiting";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32"/></svg>';

const card = (id: number, since: string): WaitingCard => ({
  id,
  title: `card ${id}`,
  column: "local_human_review",
  column_label: "Local: Human review",
  kind: "ask",
  since,
  needs_operator: true,
  blocked: false,
  question_first_line: null,
  owner_session: null,
  approved: null,
  approved_by: null,
  carried_on: null,
});
const waiting = (cards: WaitingCard[]): Waiting => ({
  waiting_columns: [],
  total: cards.length,
  projects: [{ slug: "p", icon: null, count: cards.length, cards }],
  held: [],
  external: [],
  approved: [],
  launch_failures: [],
  lead_ends: [],
});

let hidden = false;
let focused = true;
let root: Root;
let host: HTMLElement;
// a fresh module per test: the alert keeps its drawn count and favicon read at module level
let mod: typeof import("./tabAlert");

function Probe({ data }: { data: Waiting | null }) {
  mod.useNewWaitingAlert(data);
  return null;
}
const render = (data: Waiting | null) =>
  act(async () => {
    root.render(createElement(Probe, { data }));
    await Promise.resolve();
  });
const icon = () => document.querySelector<HTMLLinkElement>('link[rel="icon"]')!;
const meta = () => document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
// lets the favicon fetch (a resolved promise chain) land
const settle = () => act(() => new Promise<void>((r) => setTimeout(r, 0)));

function away() {
  hidden = true;
  focused = false;
  act(() => {
    window.dispatchEvent(new Event("blur"));
  });
}
function look() {
  hidden = false;
  focused = true;
  act(() => {
    window.dispatchEvent(new Event("focus"));
  });
}

beforeEach(async () => {
  vi.resetModules();
  hidden = false;
  focused = true;
  Object.defineProperty(document, "hidden", {
    configurable: true,
    get: () => hidden,
  });
  vi.spyOn(document, "hasFocus").mockImplementation(() => focused);
  vi.stubGlobal(
    "fetch",
    vi.fn(() =>
      Promise.resolve(
        new Response(ICON, {
          status: 200,
          headers: { "content-type": "image/svg+xml" },
        }),
      ),
    ),
  );
  localStorage.clear();
  document.head.innerHTML = '<link rel="icon" href="/static/icon.svg">';
  document.documentElement.style.setProperty("--vivid-purple", "#bf5af2");
  document.title = "busyyaks";
  mod = await import("./tabAlert");
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("useNewWaitingAlert in a page", () => {
  it("first read is the baseline: the cards waiting already never alert", async () => {
    away();
    await render(waiting([card(1, "t1")]));
    expect(document.title).toBe("busyyaks");
    expect(meta()).toBeNull();
    expect(JSON.parse(localStorage.getItem(SEEN_KEY)!)).toEqual(["1@t1"]);
  });

  it("a card that starts waiting while away → title, favicon dot, theme-color; looking clears all three", async () => {
    await render(waiting([]));
    away();
    await render(waiting([card(2, "t2")]));
    await settle();
    expect(document.title).toBe("(1 new) busyyaks");
    expect(icon().getAttribute("href")).toMatch(/^data:image\/svg\+xml,/);
    expect(decodeURIComponent(icon().getAttribute("href")!)).toContain("#bf5af2");
    expect(meta()?.content).toBe("#bf5af2");

    look();
    expect(document.title).toBe("busyyaks");
    expect(icon().getAttribute("href")).toBe("/static/icon.svg");
    expect(meta()).toBeNull();
    // the card still waits: looking marked it seen, it is not alerted again
    away();
    await render(waiting([card(2, "t2")]));
    expect(document.title).toBe("busyyaks");
  });

  it("a card that starts waiting while the operator looks never alerts, also after looking stops", async () => {
    await render(waiting([]));
    await render(waiting([card(3, "t3")]));
    away();
    expect(document.title).toBe("busyyaks");
    expect(meta()).toBeNull();
  });

  it("a hidden tab alerts even while its window has focus", async () => {
    await render(waiting([]));
    hidden = true;
    act(() => {
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await render(waiting([card(4, "t4")]));
    expect(document.title).toBe("(1 new) busyyaks");
  });

  it("another tab looking (the shared seen set changes) clears this tab", async () => {
    await render(waiting([]));
    away();
    await render(waiting([card(5, "t5")]));
    expect(document.title).toBe("(1 new) busyyaks");

    localStorage.setItem(SEEN_KEY, JSON.stringify(["5@t5"]));
    act(() => {
      window.dispatchEvent(new StorageEvent("storage", { key: SEEN_KEY }));
    });
    expect(document.title).toBe("busyyaks");
    expect(meta()).toBeNull();
  });

  it("the widget leaving the page takes its alert with it", async () => {
    await render(waiting([]));
    away();
    await render(waiting([card(6, "t6")]));
    await settle();
    expect(document.title).toBe("(1 new) busyyaks");
    act(() => root.unmount());
    expect(document.title).toBe("busyyaks");
    expect(icon().getAttribute("href")).toBe("/static/icon.svg");
    expect(meta()).toBeNull();
    root = createRoot(host);
  });

  it("a favicon that cannot be dotted (not an SVG) is a console warning, never an unhandled rejection; the title still alerts", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response("not an svg", { status: 200 }))),
    );
    await render(waiting([]));
    away();
    await render(waiting([card(7, "t7")]));
    await settle();
    expect(document.title).toBe("(1 new) busyyaks");
    expect(icon().getAttribute("href")).toBe("/static/icon.svg");
    expect(warn).toHaveBeenCalledWith("new-waiting favicon dot not drawn:", expect.any(Error));
  });

  it("a favicon read that fails is not kept: the next alert reads it again", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response("", { status: 503 }))
      .mockResolvedValue(new Response(ICON, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await render(waiting([]));
    away();
    await render(waiting([card(8, "t8")]));
    await settle();
    expect(icon().getAttribute("href")).toBe("/static/icon.svg");
    expect(warn).toHaveBeenCalled();

    look();
    away();
    await render(waiting([card(8, "t8"), card(9, "t9")]));
    await settle();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(icon().getAttribute("href")).toMatch(/^data:image\/svg\+xml,/);
  });
});
