// The live terminal's wire format (lib/busyyaks/terminal.rb): JSON text messages over /api/terminal.
// Server → browser: the first message {ok, session, cols, rows, screen} (screen = the pane now, base64), then
// {o} output · {size} the pane resized · {control} the control state the launcher confirmed · {refused} a frame not
// acted on · {exit} the stream ends. Browser → server: {i} keys (acted on only in control) · {control} take / release.
export type ServerFrame =
  | { kind: "hello"; session: string; cols: number; rows: number; screen: Uint8Array }
  | { kind: "denied"; error: string }
  | { kind: "output"; data: Uint8Array }
  | { kind: "size"; cols: number; rows: number }
  | { kind: "control"; on: boolean }
  | { kind: "refused"; why: string }
  | { kind: "exit"; why: string }
  | { kind: "unknown"; raw: string };

export function fromBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let bin = "";
  const CHUNK = 0x8000; // String.fromCharCode's argument count stays bounded on a big paste
  for (let i = 0; i < bytes.length; i += CHUNK) bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  return btoa(bin);
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const posInt = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v > 0;

// One server message → a frame; anything that is not one of the protocol's is `unknown` (shown, never acted on).
export function parseServer(raw: string): ServerFrame {
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    return { kind: "unknown", raw };
  }
  if (!isObj(v)) return { kind: "unknown", raw };
  if (
    v.ok === true &&
    typeof v.session === "string" &&
    posInt(v.cols) &&
    posInt(v.rows) &&
    typeof v.screen === "string"
  )
    return { kind: "hello", session: v.session, cols: v.cols, rows: v.rows, screen: fromBase64(v.screen) };
  if (v.ok === false) return { kind: "denied", error: typeof v.error === "string" ? v.error : "refused" };
  if (typeof v.o === "string") return { kind: "output", data: fromBase64(v.o) };
  if (isObj(v.size) && posInt(v.size.cols) && posInt(v.size.rows))
    return { kind: "size", cols: v.size.cols, rows: v.size.rows };
  if (typeof v.control === "boolean") return { kind: "control", on: v.control };
  if (typeof v.refused === "string") return { kind: "refused", why: v.refused };
  if (typeof v.exit === "string") return { kind: "exit", why: v.exit };
  return { kind: "unknown", raw };
}

// keys typed (xterm's onData: a JS string) → {i}: its UTF-8 bytes, base64
export const inputFrame = (keys: string): string => JSON.stringify({ i: toBase64(new TextEncoder().encode(keys)) });
export const controlFrame = (on: boolean): string => JSON.stringify({ control: on });

// ws(s)://<this host>/api/terminal?session=&socket= — the page's own origin, so the server's Origin check holds
export function terminalUrl(loc: { protocol: string; host: string }, session: string, socket: string): string {
  const scheme = loc.protocol === "https:" ? "wss:" : "ws:";
  const q = new URLSearchParams({ session, socket });
  return `${scheme}//${loc.host}/api/terminal?${q.toString()}`;
}

// A close before the first message: the server refused the upgrade with an HTTP status the browser does not show.
export const REFUSED_BEFORE_OPEN =
  "refused before it opened: signed out, a session busyyaks did not register, not running, too many open " +
  "(terminal.max_open), or opened through PUBLIC_HOST with terminal.public_host: deny";
