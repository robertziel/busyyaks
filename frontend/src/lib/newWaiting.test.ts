import { afterEach, describe, expect, it, vi } from "vitest";
import { shouldPoll } from "./live";
import { get } from "./store";
import { alertPass, dottedIcon, readSeen, SEEN_KEY, step, titlePrefix, waitingKeys } from "./newWaiting";
import type { Waiting, WaitingCard } from "./waiting";

const card = (id: number, since: string | null, kind = "ask"): WaitingCard => ({
  id,
  title: `card ${id}`,
  column: "local_human_review",
  column_label: "Local: Human review",
  kind,
  since,
  needs_operator: kind === "ask",
  blocked: false,
  question_first_line: null,
  owner_session: null,
  approved: null,
  approved_by: null,
  carried_on: null,
});
const waiting = (cards: WaitingCard[], extra: Partial<Waiting> = {}): Waiting => ({
  waiting_columns: [],
  total: cards.length,
  projects: [{ slug: "p", icon: null, count: cards.length, cards }],
  held: [],
  external: [],
  approved: [],
  launch_failures: [],
  lead_ends: [],
  ...extra,
});
const store = (v: string | null) => ({ getItem: () => v });

describe("waitingKeys", () => {
  it("keys each waiting card by id + the time it started waiting (the column when unknown)", () => {
    expect(waitingKeys(waiting([card(1, "2026-11-24T10:00:00Z"), card(2, null, "review")]))).toEqual([
      "1@2026-11-24T10:00:00Z",
      "2@local_human_review",
    ]);
  });

  it("counts only what waits for the operator: never held, external or approved cards", () => {
    const other = [{ slug: "q", icon: null, count: 1, cards: [card(9, "t")] }];
    expect(waitingKeys(waiting([], { held: other, external: other, approved: other }))).toEqual([]);
  });
});

describe("readSeen", () => {
  // a failing expect never leaves a stubbed localStorage to the next test
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("nothing stored = null (this browser's first read)", () => {
    expect(readSeen(store(null))).toBeNull();
  });

  it("reads the stored list", () => {
    expect(readSeen(store(JSON.stringify(["1@t"])))).toEqual(new Set(["1@t"]));
  });

  it("blocked storage (getItem throws) never throws through lib/store: nothing seen, no alert", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("SecurityError");
      },
    });
    const seen = readSeen({ getItem: get });
    expect(seen).toBeNull();
    expect(step(["1@t"], seen, false).fresh).toEqual([]);
  });

  it("a value that is not a list of keys is an error on the console and read as nothing seen yet", () => {
    const warn = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(readSeen(store("{bad"))).toBeNull();
    expect(readSeen(store("[1]"))).toBeNull();
    expect(warn).toHaveBeenCalledTimes(2);
    expect(warn).toHaveBeenCalledWith(expect.stringContaining(SEEN_KEY));
    warn.mockRestore();
  });
});

describe("step", () => {
  it("the first read is the baseline: what waits already is never new", () => {
    expect(step(["1@t"], null, false)).toEqual({ write: ["1@t"], fresh: [] });
  });

  it("a card that arrives while the operator is not looking alerts", () => {
    expect(step(["1@t", "2@u"], new Set(["1@t"]), false)).toEqual({ write: null, fresh: ["2@u"] });
  });

  it("a card that arrives while the operator looks never alerts — it is seen at once", () => {
    expect(step(["1@t", "2@u"], new Set(["1@t"]), true)).toEqual({ write: ["1@t", "2@u"], fresh: [] });
  });

  it("looking resets the alert though the cards still wait", () => {
    const seen = new Set(["1@t"]);
    expect(step(["1@t", "2@u"], seen, false).fresh).toEqual(["2@u"]);
    expect(step(["1@t", "2@u"], seen, true)).toEqual({ write: ["1@t", "2@u"], fresh: [] });
  });

  it("a card that left the waiting set and came back (a new since) is new again", () => {
    expect(step(["1@later"], new Set(["1@t"]), false).fresh).toEqual(["1@later"]);
  });

  it("cards dealt with elsewhere leave no alert and keep the seen set as it is", () => {
    expect(step([], new Set(["1@t"]), false)).toEqual({ write: null, fresh: [] });
  });
});

describe("titlePrefix", () => {
  it("names the new cards; none = no prefix", () => {
    expect(titlePrefix(0)).toBe("");
    expect(titlePrefix(2)).toBe("(2 new) ");
  });
});

describe("dottedIcon", () => {
  it("adds the dot as the icon's last shape", () => {
    const url = dottedIcon('<svg viewBox="0 0 240 240"><rect/></svg>', "#bf5af2");
    const svg = decodeURIComponent(url.replace("data:image/svg+xml,", ""));
    expect(svg).toMatch(/<rect\/><circle [^>]*fill="#bf5af2"[^>]*\/><\/svg>$/);
  });

  it("refuses a favicon that is not SVG", () => {
    expect(() => dottedIcon("PNG", "#000")).toThrow(/not an SVG/);
  });
});

// the page's side as stubs: localStorage (shared by the "tabs" given the same map), looking, the drawn count
function page(storage: Map<string, string>, look: boolean) {
  const drawn: number[] = [];
  const env = {
    looking: () => env.look,
    look,
    read: () => storage.get(SEEN_KEY) ?? null,
    write: (v: string) => void storage.set(SEEN_KEY, v),
    draw: (n: number) => void drawn.push(n),
  };
  return { env, drawn };
}

describe("alertPass", () => {
  it("away → a new card draws (1 new); looking again draws 0 though it still waits", () => {
    const storage = new Map<string, string>();
    const { env, drawn } = page(storage, false);
    let shown = alertPass(waiting([card(1, "t")]), env, -1); // baseline
    shown = alertPass(waiting([card(1, "t"), card(2, "u")]), env, shown);
    expect(drawn).toEqual([0, 1]);
    env.look = true;
    shown = alertPass(waiting([card(1, "t"), card(2, "u")]), env, shown);
    expect(drawn).toEqual([0, 1, 0]);
    expect(JSON.parse(storage.get(SEEN_KEY)!)).toEqual(["1@t", "2@u"]);
    expect(shown).toBe(0);
  });

  it("draws only on a change of the count", () => {
    const { env, drawn } = page(new Map([[SEEN_KEY, "[]"]]), false);
    let shown = alertPass(waiting([card(1, "t")]), env, -1);
    shown = alertPass(waiting([card(1, "t")]), env, shown);
    expect(drawn).toEqual([1]);
    expect(shown).toBe(1);
  });

  it("looking in one tab clears another (the shared seen set, read again on its storage event)", () => {
    const storage = new Map([[SEEN_KEY, "[]"]]);
    const away = page(storage, false);
    const here = page(storage, true);
    const w = waiting([card(1, "t")]);
    let shownAway = alertPass(w, away.env, -1);
    expect(away.drawn).toEqual([1]);
    alertPass(w, here.env, -1);
    shownAway = alertPass(w, away.env, shownAway);
    expect(away.drawn).toEqual([1, 0]);
    expect(shownAway).toBe(0);
  });

  it("storage that keeps nothing: every pass is a baseline, nothing drawn but the reset", () => {
    const env = { read: () => null, write: () => {}, looking: () => false, draw: vi.fn() };
    const shown = alertPass(waiting([card(1, "t")]), env, -1);
    expect(alertPass(waiting([card(1, "t"), card(2, "u")]), env, shown)).toBe(0);
    expect(env.draw.mock.calls).toEqual([[0]]);
  });
});

describe("shouldPoll", () => {
  it("a visible tab polls; a hidden one only with whileHidden; a pause never", () => {
    expect(shouldPoll(false, false, false)).toBe(true);
    expect(shouldPoll(true, false, false)).toBe(false);
    expect(shouldPoll(true, true, false)).toBe(true);
    expect(shouldPoll(false, true, true)).toBe(false);
  });
});
