// The dictation shortcut: this browser's choice, set on Settings → Shortcuts. A per-viewer convenience like
// the skin, so localStorage: nothing stored = ⌥R / Alt+R (R = record; not ⌥M, which a macOS app can hold as a
// global hotkey — the browser never sees the key); a stored value that is no
// longer a valid combo is said on the settings page (and no key is bound) — never silently replaced.
import { comboLabel, comboRefusal, parseCombo, type KeyCombo } from "../vendor/agents_kanban";

export const STORE_KEY = "busyyaks.dictation-shortcut";
export const DEFAULT_SHORTCUT: KeyCombo = { code: "KeyR", alt: true, ctrl: false, meta: false, shift: false };
export const CHANGED = "busyyaks:dictation-shortcut";

export type ShortcutState = { combo: KeyCombo | null; stored: boolean; error: string | null };

type Storage = Pick<globalThis.Storage, "getItem" | "setItem" | "removeItem">;

const store = (): Storage | null => {
  try {
    return window.localStorage;
  } catch {
    return null; // storage blocked: the default applies, and the page says choices are not kept
  }
};

export function readShortcut(s: Storage | null = store()): ShortcutState {
  let raw: string | null = null;
  try {
    raw = s ? s.getItem(STORE_KEY) : null;
  } catch {
    raw = null;
  }
  if (raw === null) return { combo: DEFAULT_SHORTCUT, stored: false, error: null };
  if (raw === "none") return { combo: null, stored: true, error: null };
  let parsed: unknown = null;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = null;
  }
  const combo = parseCombo(parsed);
  const refused = combo && comboRefusal(combo);
  if (!combo || refused)
    return { combo: null, stored: true, error: `the saved shortcut is not usable${refused ? `: ${refused}` : ""}` };
  return { combo, stored: true, error: null };
}

// combo = the new key; null = no shortcut (mic button only); "default" = forget the choice
export function writeShortcut(v: KeyCombo | null | "default", s: Storage | null = store()): string | null {
  if (v && v !== "default") {
    const why = comboRefusal(v);
    if (why) return why;
  }
  if (!s) return "this browser does not keep settings (storage is blocked)";
  try {
    if (v === "default") s.removeItem(STORE_KEY);
    else s.setItem(STORE_KEY, v === null ? "none" : JSON.stringify(v));
  } catch {
    return "this browser does not keep settings (storage is blocked)";
  }
  document.dispatchEvent(new CustomEvent(CHANGED));
  return null;
}

// a keydown → the combo it is (the key by position), or null for a lone modifier press
export function comboOf(
  e: Pick<KeyboardEvent, "code" | "altKey" | "ctrlKey" | "metaKey" | "shiftKey">,
): KeyCombo | null {
  if (/^(Alt|Control|Meta|Shift|OS)(Left|Right)?$/.test(e.code)) return null;
  return { code: e.code, alt: e.altKey, ctrl: e.ctrlKey, meta: e.metaKey, shift: e.shiftKey };
}

// while a shortcut is being recorded: the modifiers held so far (code "" = the key is still to come), null when none
export function heldOf(e: Pick<KeyboardEvent, "altKey" | "ctrlKey" | "metaKey" | "shiftKey">): KeyCombo | null {
  if (!e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey) return null;
  return { code: "", alt: e.altKey, ctrl: e.ctrlKey, meta: e.metaKey, shift: e.shiftKey };
}

// the recorder's cancel button: Esc cancels too — said only where there is a keyboard (a touch screen has no Esc key)
export const cancelLabel = (touch: boolean): string => (touch ? "Cancel" : "Cancel (Esc)");
export const touchScreen = (w: Pick<Window, "matchMedia"> = window): boolean => w.matchMedia("(hover: none)").matches;

// Recording, the modifiers held and no key yet: what Settings → Shortcuts says once the key has not come (a CSS delay).
// A combination taken before the page — a global hotkey of another app, the OS or the browser — never reaches it: only
// its modifiers do (e.g. ⌥M on a Mac where another app holds it).
export const takenHint = (held: KeyCombo, mac: boolean): string =>
  `${comboLabel(held, mac)} held but no key arrives? Another app, the system or the browser takes that combination before this page — try another key.`;
