// The dictation shortcut in this browser: nothing stored = ⌥R; a saved combo, "none", a refused or unreadable value
// (said, no key bound); writes refuse a combo the browser / OS / editor owns and say when storage is blocked.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  cancelLabel,
  comboOf,
  DEFAULT_SHORTCUT,
  heldOf,
  readShortcut,
  STORE_KEY,
  takenHint,
  touchScreen,
  writeShortcut,
} from "./dictationShortcut";

function mem() {
  const m = new Map<string, string>();
  return {
    m,
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
  };
}
const ctrlAltD = { code: "KeyD", alt: true, ctrl: true, meta: false, shift: false };

describe("dictation shortcut", () => {
  const events: string[] = [];
  beforeEach(() => {
    events.length = 0;
    vi.stubGlobal("document", { dispatchEvent: (e: Event) => events.push(e.type) });
    vi.stubGlobal(
      "CustomEvent",
      class {
        constructor(public type: string) {}
      },
    );
  });
  afterEach(() => vi.unstubAllGlobals());

  it("nothing stored = ⌥R; a saved combo; none; a refused or unreadable value is said and binds nothing", () => {
    const s = mem();
    expect(readShortcut(s)).toEqual({ combo: DEFAULT_SHORTCUT, stored: false, error: null });
    expect(writeShortcut(ctrlAltD, s)).toBeNull();
    expect(readShortcut(s)).toEqual({ combo: ctrlAltD, stored: true, error: null });
    expect(events).toEqual(["busyyaks:dictation-shortcut"]);
    expect(writeShortcut(null, s)).toBeNull();
    expect(readShortcut(s)).toEqual({ combo: null, stored: true, error: null });
    s.m.set(STORE_KEY, "{oops");
    expect(readShortcut(s)).toEqual({ combo: null, stored: true, error: "the saved shortcut is not usable" });
    s.m.set(STORE_KEY, JSON.stringify({ code: "KeyS", alt: false, ctrl: false, meta: true, shift: false }));
    expect(readShortcut(s).error).toMatch(/not usable: saves the page/);
    expect(writeShortcut("default", s)).toBeNull();
    expect(readShortcut(s).combo).toEqual(DEFAULT_SHORTCUT);
  });

  it("refuses a taken combo and blocked storage, writing nothing", () => {
    const s = mem();
    expect(writeShortcut({ ...ctrlAltD, code: "KeyW", alt: false }, s)).toMatch(/closes the tab/);
    expect(s.m.size).toBe(0);
    expect(writeShortcut(ctrlAltD, null)).toMatch(/storage is blocked/);
    const throwing = {
      ...mem(),
      setItem: () => {
        throw new Error("quota");
      },
    };
    expect(writeShortcut(ctrlAltD, throwing)).toMatch(/storage is blocked/);
    expect(events).toEqual([]);
  });

  it("a keydown is a combo by key position; a lone modifier is none", () => {
    const e = { code: "KeyR", altKey: true, ctrlKey: false, metaKey: false, shiftKey: false };
    expect(comboOf(e)).toEqual(DEFAULT_SHORTCUT);
    expect(comboOf({ ...e, code: "AltLeft" })).toBeNull();
  });

  it("while recording: the modifiers held so far, the key still to come; none held = null", () => {
    const e = { altKey: true, ctrlKey: false, metaKey: false, shiftKey: true };
    expect(heldOf(e)).toEqual({ code: "", alt: true, ctrl: false, meta: false, shift: true });
    expect(heldOf({ altKey: false, ctrlKey: false, metaKey: false, shiftKey: false })).toBeNull();
  });

  it("the recorder's Cancel names Esc only where there is a keyboard", () => {
    const screenOf = (hoverNone: boolean) => ({
      matchMedia: (q: string) => ({ matches: q === "(hover: none)" && hoverNone }) as MediaQueryList,
    });
    expect(touchScreen(screenOf(true))).toBe(true);
    expect(touchScreen(screenOf(false))).toBe(false);
    expect(cancelLabel(true)).toBe("Cancel");
    expect(cancelLabel(false)).toBe("Cancel (Esc)");
  });

  it("the taken-key hint names the modifiers held, in the platform's words", () => {
    const alt = { code: "", alt: true, ctrl: false, meta: false, shift: false };
    expect(takenHint(alt, true)).toMatch(/^⌥ held but no key arrives\? Another app, the system or the browser takes/);
    expect(takenHint({ ...alt, shift: true }, false)).toMatch(/^Alt\+Shift held but no key arrives/);
  });
});
