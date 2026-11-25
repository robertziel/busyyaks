// Card 611: the tab / window says when something NEW waits for the operator while they are not looking — the title
// gets "(N new) ", the favicon a dot, the browser's top bar (`theme-color`: the installed app's title bar, mobile
// address bars) the to-answer colour. Looking at the app (the page visible and focused) resets it at once, whether or
// not the cards are dealt with: it says "something popped up", never "something is still open" (the widget and the
// dock badge say that). A card that arrives while the operator is looking never raises it.
//
// "Seen" = the waiting cards as they were the last time the operator looked, kept in localStorage so every tab and
// window of the app shares it: looking in one clears the others (the `storage` event). A card is keyed by its id and
// the time it started waiting, so a card that leaves the waiting set and comes back is new again.
import type { Waiting } from "./waiting";

export const SEEN_KEY = "busyyaks.waiting-seen";

// the cards counted as waiting for the operator (the widget's total, the dock badge: to answer + to review)
export const waitingKeys = (w: Waiting): string[] =>
  w.projects.flatMap((p) => p.cards.map((c) => `${c.id}@${c.since ?? c.column}`));

// lib/store's never-throwing `get` in the page (blocked storage reads as null)
type Storage = { getItem(k: string): string | null };

// null = nothing kept yet (this browser's first read) or a value that is not a list of keys: an error on the console,
// and the next write replaces it (the set is this browser's own view state, written only here; alerting on every
// waiting card instead would be the false alarm card 611 forbids)
export function readSeen(storage: Storage): Set<string> | null {
  const raw = storage.getItem(SEEN_KEY);
  if (raw === null) return null;
  try {
    const v: unknown = JSON.parse(raw);
    if (Array.isArray(v) && v.every((k) => typeof k === "string")) return new Set(v);
  } catch {
    // reported below
  }
  console.error(`${SEEN_KEY}: stored value is not a list of card keys — replaced by the cards waiting now`);
  return null;
}

// One step: `write` = the keys to keep as seen (null = keep what is stored), `fresh` = the cards to alert on.
// Nothing kept yet = this browser's baseline: whatever waits now is not "new" (no alarm on a first load).
export function step(
  keys: string[],
  seen: Set<string> | null,
  looking: boolean,
): { write: string[] | null; fresh: string[] } {
  if (looking || seen === null) return { write: keys, fresh: [] };
  return { write: null, fresh: keys.filter((k) => !seen.has(k)) };
}

export const titlePrefix = (fresh: number) => (fresh > 0 ? `(${fresh} new) ` : "");

// the favicon with the alert's dot (top right, ringed in the icon's own plate colour so it reads on any tab strip)
export function dottedIcon(svg: string, color: string): string {
  const end = svg.lastIndexOf("</svg>");
  if (end < 0) throw new Error("favicon is not an SVG document");
  const dot = `<circle cx="190" cy="50" r="46" fill="${color}" stroke="#0F1115" stroke-width="10"/>`;
  return `data:image/svg+xml,${encodeURIComponent(svg.slice(0, end) + dot + svg.slice(end))}`;
}

// One pass of the alert: read the seen set, keep it when the operator looks (or on the first read), draw the new
// count when it changed. Returns the count drawn. `env` is the page (lib/tabAlert.ts) or a test's stubs.
export type AlertEnv = {
  read(): string | null;
  write(value: string): void;
  looking(): boolean;
  draw(fresh: number): void;
};
export function alertPass(w: Waiting, env: AlertEnv, shown: number): number {
  const { write, fresh } = step(waitingKeys(w), readSeen({ getItem: () => env.read() }), env.looking());
  if (write) env.write(JSON.stringify(write));
  if (fresh.length !== shown) env.draw(fresh.length);
  return fresh.length;
}
