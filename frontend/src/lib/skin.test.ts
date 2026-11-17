/// <reference types="node" />
// public/static/skin.js (the render-blocking skin choice, outside the bundle) run in a stub browser: the default skin is
// dark (card #528), auto follows the system, a bad stored value is removed, and choosing the default clears the key.
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";

const SOURCE = readFileSync(new URL("../../../public/static/skin.js", import.meta.url), "utf8");
const KEY = "busyyaks.skin";

type Skin = { choices: string[]; label(c: string): string; get(): string; set(c: string): void };
// the page's <meta name="skins"> as the server writes it (Busyyaks::Skins.meta): the two base skin files first
const BASES = [
  { key: "light", label: "Light", base: "light" },
  { key: "dark", label: "Dark", base: "dark" },
];
const META = JSON.stringify(BASES);

// `throws`: the localStorage calls that throw (a browser that keeps nothing: private mode, storage blocked)
// `skins`: the page's <meta name="skins"> content (null = no such meta)
function boot(
  stored: string | null,
  systemDark: boolean,
  throws: ("get" | "set" | "remove")[] = [],
  skins: string | null = META,
) {
  const store = new Map<string, string>(stored == null ? [] : [[KEY, stored]]);
  const attrs = new Map<string, string>();
  const errors: string[] = [];
  let onSystem: () => void = () => {};
  const mq = {
    matches: systemDark,
    addEventListener: (_: string, fn: () => void) => (onSystem = fn),
  };
  const window: { matchMedia: () => typeof mq; busyyaksSkin?: Skin } = { matchMedia: () => mq };
  runInNewContext(SOURCE, {
    window,
    localStorage: {
      getItem: (k: string) => {
        if (throws.includes("get")) throw new Error("SecurityError");
        return store.get(k) ?? null;
      },
      setItem: (k: string, v: string) => {
        if (throws.includes("set")) throw new Error("QuotaExceededError");
        store.set(k, v);
      },
      removeItem: (k: string) => {
        if (throws.includes("remove")) throw new Error("SecurityError");
        store.delete(k);
      },
    },
    document: {
      documentElement: {
        setAttribute: (k: string, v: string) => attrs.set(k, v),
        removeAttribute: (k: string) => attrs.delete(k),
        style: {},
      },
      querySelector: (q: string) =>
        q === 'meta[name="skins"]' && skins !== null ? { getAttribute: () => skins } : null,
      dispatchEvent: () => true,
    },
    CustomEvent: class {
      constructor(
        public type: string,
        public init: unknown,
      ) {}
    },
    console: { error: (m: string) => errors.push(m) },
  });
  const skin = window.busyyaksSkin;
  if (!skin) throw new Error("skin.js set no window.busyyaksSkin");
  const system = (dark: boolean) => {
    mq.matches = dark;
    onSystem();
  };
  return {
    skin,
    store,
    errors,
    system,
    shown: () => attrs.get("data-skin"),
    choice: () => attrs.get("data-skin-choice"),
    key: () => attrs.get("data-skin-key"),
  };
}

describe("skin.js", () => {
  it("shows dark when nothing is stored, even on a light system", () => {
    const b = boot(null, false);
    expect(b.skin.get()).toBe("dark");
    expect(b.shown()).toBe("dark");
    expect(b.key()).toBe("dark");
  });

  it("lists light, dark, then auto", () => {
    expect(boot(null, false).skin.choices).toEqual(["light", "dark", "auto"]);
  });

  it("keeps a stored light, even on a dark system", () => {
    const b = boot("light", true);
    expect(b.shown()).toBe("light");
    expect(b.choice()).toBe("light");
  });

  it("keeps a stored dark (written by an earlier version), even on a light system", () => {
    const b = boot("dark", false);
    expect(b.shown()).toBe("dark");
    expect(b.choice()).toBe("dark");
  });

  it("marks the choice beside the skin: auto shows the system's skin", () => {
    const b = boot("auto", true);
    expect(b.choice()).toBe("auto");
    expect(b.shown()).toBe("dark");
  });

  it("shows dark when localStorage cannot be read", () => {
    const b = boot("light", false, ["get"]);
    expect(b.skin.get()).toBe("dark");
    expect(b.shown()).toBe("dark");
  });

  it("applies a choice it cannot store for this visit only, and says so", () => {
    const b = boot(null, false, ["set", "remove"]);
    b.skin.set("dark");
    expect(b.shown()).toBe("dark");
    expect(b.store.has(KEY)).toBe(false);
    b.skin.set("light");
    expect(b.shown()).toBe("light");
    expect(b.errors.join("\n")).toMatch(/keeps no skin choice — dark for this visit only/);
    expect(b.errors.join("\n")).toMatch(/keeps no skin choice — light for this visit only/);
  });

  it("removes a bad stored value it then cannot delete, and still shows dark", () => {
    const b = boot("sepia", false, ["remove"]);
    expect(b.shown()).toBe("dark");
  });

  it("follows the system live on auto", () => {
    const b = boot("auto", true);
    expect(b.shown()).toBe("dark");
    b.system(false);
    expect(b.shown()).toBe("light");
  });

  it("ignores the system when the choice is not auto", () => {
    const b = boot(null, true);
    b.system(false);
    expect(b.shown()).toBe("dark");
  });

  it("removes a stored value that is no choice, says so, and shows dark", () => {
    const b = boot("sepia", false);
    expect(b.shown()).toBe("dark");
    expect(b.store.has(KEY)).toBe(false);
    expect(b.errors.join()).toMatch(/"sepia" is not one of light, dark, auto/);
  });

  it("stores auto and light, and clears the key for the default", () => {
    const b = boot(null, false);
    b.skin.set("auto");
    expect(b.store.get(KEY)).toBe("auto");
    expect(b.shown()).toBe("light");
    b.skin.set("light");
    expect(b.store.get(KEY)).toBe("light");
    b.skin.set("dark");
    expect(b.store.has(KEY)).toBe(false);
    expect(b.shown()).toBe("dark");
  });

  it("refuses an unknown choice", () => {
    expect(() => boot(null, false).skin.set("sepia")).toThrow(/unknown skin "sepia"/);
  });

  it("marks the shown skin's key beside its base: auto shows the system's", () => {
    const b = boot("auto", true);
    expect(b.key()).toBe("dark");
    b.system(false);
    expect(b.key()).toBe("light");
  });

  describe("skin files (card #361)", () => {
    const DUSK = JSON.stringify([...BASES, { key: "dusk", label: "Dusk", base: "dark" }]);

    it("lists an added skin after light, dark, auto, with the labels from the files", () => {
      const b = boot(null, false, [], DUSK);
      expect(b.skin.choices).toEqual(["light", "dark", "auto", "dusk"]);
      expect(b.skin.label("dusk")).toBe("Dusk");
      expect(b.skin.label("light")).toBe("Light");
      expect(b.skin.label("auto")).toBe("Auto");
    });

    it("shows a stored added skin as its base plus its key", () => {
      const b = boot("dusk", false, [], DUSK);
      expect(b.shown()).toBe("dark");
      expect(b.key()).toBe("dusk");
      expect(b.choice()).toBe("dusk");
    });

    it("stores a chosen added skin; dark clears the key", () => {
      const b = boot(null, false, [], DUSK);
      b.skin.set("dusk");
      expect(b.store.get(KEY)).toBe("dusk");
      expect(b.key()).toBe("dusk");
      b.skin.set("dark");
      expect(b.key()).toBe("dark");
      expect(b.store.has(KEY)).toBe(false);
    });

    it("removes a stored skin whose file is gone, says so, and shows dark", () => {
      const b = boot("dusk", false);
      expect(b.shown()).toBe("dark");
      expect(b.store.has(KEY)).toBe(false);
      expect(b.errors.join()).toMatch(/"dusk" is not one of light, dark, auto —/);
    });

    it("throws on a malformed list or one without a base skin, never reads it as none", () => {
      expect(() => boot(null, false, [], JSON.stringify([...BASES, { key: "x", label: "X", base: "sepia" }]))).toThrow(
        /bad skin/,
      );
      expect(() =>
        boot(null, false, [], JSON.stringify([...BASES, { key: "auto", label: "A", base: "dark" }])),
      ).toThrow(/called auto/);
      expect(() => boot(null, false, [], JSON.stringify([BASES[0]]))).toThrow(/lists no dark skin/);
      expect(() => boot(null, false, [], "{}")).toThrow(/must be a list/);
    });

    it("throws on a page without the skins meta", () => {
      expect(() => boot(null, false, [], null)).toThrow(/no <meta name="skins">/);
    });
  });
});
