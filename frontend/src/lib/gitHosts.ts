// Settings → Git hosts: GET /api/settings/git-hosts's shape and what the page derives from it — each
// provider's card state, the collector's line, why Connect is off, a refusal as shown, the Summary's line and the
// "not connected" sentence split around its link. The server validates the token (GitHub's /user); its refusal is
// shown verbatim. Pure: tested by gitHosts.test.ts.
import { ago } from "./format";

export const GIT_HOSTS_KEY = "/api/settings/git-hosts";
export const GIT_HOSTS_PATH = "/settings/git-hosts";

export type GitHostProvider = { key: string; label: string; available: boolean; note: string | null };
export type GitHostConnection = {
  id: number;
  provider: string;
  label: string;
  login: string;
  token_hint: string; // "…abcd": the token itself never leaves the github service
  author: string;
  at: number; // unix s
};
export type GitHostCollector = { ok: boolean; error: string | null; at: number | null };
export type GitHostsData = {
  providers: GitHostProvider[];
  current: GitHostConnection | null;
  collector: GitHostCollector | null; // the connected login's last GitHub run; null = none yet
};

// one provider's card: connected (this provider is the current one), open (can be connected), soon (not available)
// POST /api/settings/git-hosts/test: the stored token asked again; same = its login is still the connected one
export type GitHostTest = { ok: boolean; login: string; same: boolean };

export const testedLine = (t: GitHostTest): string =>
  t.same
    ? `Token works: GitHub answers as ${t.login}`
    : `Token works, but GitHub answers as ${t.login}, not the connected login: connect it again`;

export type CardState = "connected" | "open" | "soon";
export function cardState(p: GitHostProvider, current: GitHostConnection | null): CardState {
  if (current && current.provider === p.key) return "connected";
  return p.available ? "open" : "soon";
}

// the collector's last run as one line + its tone; null run = none yet (a fresh connection)
export function collectorLine(c: GitHostCollector | null, at?: number): { tone: "ok" | "bad" | "muted"; text: string } {
  if (!c || c.at == null) return { tone: "muted", text: "collector: no run yet" };
  if (c.ok) return { tone: "ok", text: `collector ok · ${ago(c.at, at)} ago` };
  return { tone: "bad", text: `collector failed ${ago(c.at, at)} ago: ${c.error ?? "no reason recorded"}` };
}

// why Connect is off, or null
export function connectRefusal(
  token: string,
  busy: boolean,
  other: GitHostConnection | null,
  key: string,
): string | null {
  if (busy) return "connecting…";
  if (other && other.provider !== key) return `${other.label} is connected: disconnect it first`;
  if (token.trim() === "") return "paste a token";
  return null;
}

// a failed call as shown: the status and the server's words; a 504 may still have applied
export function failure(status: number, message: string): { text: string; mayApply: boolean } {
  return { text: status ? `${status} · ${message}` : message, mayApply: status === 504 };
}

// Summary's line for the wizard
export const summaryLine = (current: GitHostConnection | null): string =>
  current ? `${current.label} · ${current.login}` : "not connected (optional)";

// "GitHub not connected — Settings → Git hosts" → the lead and the part that links to the page
export function offParts(text: string): { lead: string; link: string } {
  const i = text.lastIndexOf(" — ");
  if (i < 0) return { lead: `${text} — `, link: "Settings → Git hosts" };
  return { lead: text.slice(0, i + 3), link: text.slice(i + 3) };
}
