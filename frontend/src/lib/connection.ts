// Whether the page is live, and which server it shows when that is not this machine.
//
// Remote: `yaks remote connect` / the desktop app's server chooser (`yaks desktop open`) open the dashboard as http://127.0.0.1:<port>/?remote=<host>
// through an ssh forward. The host name is the server's own (read over ssh); the window keeps it for its session
// (sessionStorage), so every page of that window shows it.
// Live: the shell polls /up; one failed read = reconnecting, two in a row = down — never a stale page posing as live.

export type Connection = "connected" | "reconnecting" | "down";

export const POLL_MS = 3000;
export const TIMEOUT_MS = 2500;
const DOWN_AFTER = 2;
const KEY = "busyyaks.remote";
const HOST = /^[A-Za-z0-9._-]{1,253}$/;

export interface Health {
  state: Connection;
  failures: number;
}

export const initialHealth: Health = { state: "connected", failures: 0 };

export function nextHealth(prev: Health, ok: boolean): Health {
  if (ok) return initialHealth;
  const failures = prev.failures + 1;
  return { state: failures >= DOWN_AFTER ? "down" : "reconnecting", failures };
}

interface Store {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
}

// ?remote=<host> (a valid host name only) → kept for the window; else the window's kept one; else null (this machine)
export function remoteHost(search: string, store: Store | null): string | null {
  const given = new URLSearchParams(search).get("remote");
  if (given !== null && HOST.test(given)) {
    try {
      store?.setItem(KEY, given);
    } catch {
      // storage off (private window): the label still shows on this page
    }
    return given;
  }
  try {
    const kept = store?.getItem(KEY) ?? null;
    return kept !== null && HOST.test(kept) ? kept : null;
  } catch {
    return null;
  }
}

export function sessionStore(): Store | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

// main.tsx calls this before the first render: a redirect (a fresh install's /hello) drops the query, so the label is
// kept from the URL the window opened with, not from whatever page the header first mounts on
export const keepRemote = (search: string, store: Store | null): void => void remoteHost(search, store);

// one read of /up: true only for a 200 within TIMEOUT_MS
export async function probe(fetcher: typeof fetch = fetch): Promise<boolean> {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try {
    const res = await fetcher("/up", { cache: "no-store", credentials: "same-origin", signal: ctl.signal });
    return res.status === 200;
  } catch {
    return false;
  } finally {
    clearTimeout(t);
  }
}
