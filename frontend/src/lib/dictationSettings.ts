// Settings → Dictation (card 634): what the card dialog's mic runs (GET /api/settings/dictation) as an editable draft
// and back, and why Save / Test / Connect are off. The server (Busyyaks::DictationSettings) stays the validator — its
// refusal is shown verbatim; the checks here mirror it (whole seconds in the limits, a URL while on, a model the
// form's server lists when on) so the buttons say why they are off before a round trip. The token is write-only: the
// page never gets it back, only whether one is set; a draft token null = keep the saved one (only for the saved URL).
// Pure: tested by dictationSettings.test.ts.

export type Revision = { id: number; author: string; at: number };
export type DictationDoc = {
  enabled: boolean;
  url: string; // the speech server's base or endpoint; "" only while off
  token: null; // never sent back
  token_set: boolean;
  token_hint: string | null; // "…abcd" (a long token's last 4)
  model: string;
  timeout_seconds: number;
  max_seconds: number;
};
// null = not read (error says why); hint = the page's own reason (no URL / not connected yet), not the server's answer
export type Models = { models: string[] | null; models_error: string | null; hint?: true };
export type DictationData = Models & {
  revision: Revision | null; // null = never saved: the mic is off
  doc: DictationDoc | null;
  limits: { timeout_seconds: [number, number]; max_seconds: [number, number] };
  history: Revision[]; // the newest 20
  revisions: number;
};
// token null = keep the saved one; a string replaces it ("" = none)
export type Draft = {
  enabled: boolean;
  url: string;
  token: string | null;
  model: string;
  timeout_seconds: string;
  max_seconds: string;
};
export type CheckResult = { text: string; words: { word: string; start: number; end: number }[]; ms: number };
// a Connect answer: the models of the server {url, token} as the form had it
export type Probe = Models & { url: string; token: string | null };

const NUMS = ["timeout_seconds", "max_seconds"] as const;
// the page's names of the two limits: a refusal names the field as the page shows it, never the document key
export const LABELS = { timeout_seconds: "Request timeout", max_seconds: "Longest recording" } as const;

// Does a read become the form? The first one, and a newer read while nothing is edited — never the read the form
// already holds: re-adopting it makes a new draft object each time, the effect runs again, and that loop overwrote the
// first keystrokes after a page load (QA, card 634).
export const adopts = (data: DictationData, draft: Draft | null, loadedFrom: DictationData | null): boolean =>
  !draft || !loadedFrom || (data !== loadedFrom && !changedKeys(draft, toDraft(loadedFrom)).length);

// no revision → an empty form, off, no token: nothing is filled in for you. A saved token = null (kept, never sent
// back); none saved = "" (none: a new URL needs no token typed, there is none to follow it)
export const toDraft = (data: DictationData): Draft =>
  data.doc
    ? {
        enabled: data.doc.enabled,
        url: data.doc.url,
        token: data.doc.token_set ? null : "",
        model: data.doc.model,
        timeout_seconds: String(data.doc.timeout_seconds),
        max_seconds: String(data.doc.max_seconds),
      }
    : { enabled: false, url: "", token: "", model: "", timeout_seconds: "", max_seconds: "" };

const num = (v: string): number | string => (/^\d+$/.test(v.trim()) ? Number(v.trim()) : v);

export const fromDraft = (d: Draft) => ({
  enabled: d.enabled,
  url: d.url.trim(),
  token: d.token,
  model: d.model,
  timeout_seconds: num(d.timeout_seconds),
  max_seconds: num(d.max_seconds),
});

export const server = (d: Draft) => ({ url: d.url.trim(), token: d.token });

export const changedKeys = (d: Draft, loaded: Draft): (keyof Draft)[] =>
  (Object.keys(d) as (keyof Draft)[]).filter((k) =>
    k === "token" ? d.token !== loaded.token : String(d[k]).trim() !== String(loaded[k]).trim(),
  );

// the form's server is the saved one (same URL, the token as saved: kept, or still none)
export const savedServer = (d: Draft, loaded: Draft): boolean =>
  d.token === loaded.token && d.url.trim() === loaded.url.trim() && loaded.url.trim() !== "";

// the model list of the form's server: the saved one's (GET), a Connect answer for exactly this server, or none yet
export function modelsFor(d: Draft, loaded: Draft, data: DictationData, probe: Probe | null): Models {
  const s = server(d);
  if (probe && probe.url === s.url && probe.token === s.token) return probe;
  if (savedServer(d, loaded)) return data;
  if (!s.url) return { models: null, models_error: "type the server's URL", hint: true };
  return { models: null, models_error: "press Connect to read its models", hint: true };
}

// why Connect (read the form's server's models) is off, or null
export function connectRefusal(d: Draft, loaded: Draft): string | null {
  if (!d.url.trim()) return "type the server's URL";
  if (!/^https?:\/\/[^/?#\s]+/.test(d.url.trim())) return "URL: http(s)://host[:port][/path]";
  if (d.token === null && !savedServer(d, loaded)) return "Token: type the new server's token (or No token)";
  return null;
}

// a seconds field's refusal, or null
export function fieldRefusal(value: string, [min, max]: [number, number]): string | null {
  if (!/^\d+$/.test(value.trim())) return `whole seconds, ${min}–${max}`;
  const n = Number(value.trim());
  return n < min || n > max ? `${min}–${max} s` : null;
}

// why Test is off (the form's server + model, on or off), or null
export function checkRefusal(d: Draft, loaded: Draft, list: Models, limits: DictationData["limits"]): string | null {
  const off = connectRefusal(d, loaded);
  if (off) return off;
  if (!list.models) return `models not read: ${list.models_error ?? "unknown"}`;
  if (!d.model) return "pick a model";
  if (!list.models.includes(d.model)) return `${d.model} is not served`;
  for (const k of NUMS) {
    const bad = fieldRefusal(d[k], limits[k]);
    if (bad) return `${LABELS[k]}: ${bad}`;
  }
  return null;
}

// why Save is off, or null; `newer` = a revision saved since the form loaded
export function saveRefusal(d: Draft, loaded: Draft, data: DictationData, list: Models, newer?: number): string | null {
  if (newer !== undefined) return `rev ${newer} saved since: reload`;
  if (!changedKeys(d, loaded).length) return "no changes";
  if (d.enabled) return checkRefusal(d, loaded, list, data.limits);
  if (d.url.trim()) {
    const off = connectRefusal(d, loaded);
    if (off) return off;
  } else if (d.token) return "token is set but url is empty";
  if (!d.model.trim()) return "pick a model"; // kept while off: on again keeps it
  for (const k of NUMS) {
    const bad = fieldRefusal(d[k], data.limits[k]);
    if (bad) return `${LABELS[k]}: ${bad}`;
  }
  return null;
}

// what the token field says: the saved one kept, replaced, or none — never a character of a short token
export function tokenLine(d: Draft, doc: DictationDoc | null): string {
  if (d.token === null)
    return doc?.token_set ? `saved (${doc.token_hint ?? "hidden"}) · leave empty to keep it` : "none saved";
  return d.token === "" ? "none · no Authorization header is sent" : `new token · ${d.token.length} characters`;
}

// the token field's placeholder
export const tokenPlaceholder = (d: Draft, doc: DictationDoc | null): string =>
  d.token === null ? (doc?.token_set ? "•••••••• saved" : "none · type one to set") : "optional";

// the speech server's one status line: what Connect / the saved server answered, or what to do first
// (`connectOff` = why Connect is off: said instead of the page's own "press Connect" hint)
export function modelsLine(
  list: Models,
  connecting: boolean,
  connectOff: string | null = null,
): { tone: "ok" | "bad" | "muted"; text: string } {
  if (connecting) return { tone: "muted", text: "connecting…" };
  if (list.hint && connectOff) return { tone: "muted", text: connectOff };
  if (list.models) {
    const n = list.models.length;
    return { tone: "ok", text: `connected · ${n} model${n === 1 ? "" : "s"} listed` };
  }
  return { tone: list.hint ? "muted" : "bad", text: list.models_error ?? "not read" };
}

// the model list the select offers: the served ones, plus the draft's model when the server does not list it
// (served false) or its list is not read yet (served null: unknown, never called "not served")
export type ModelOption = { id: string; served: boolean | null };
export function modelOptions(d: Draft, list: Models): ModelOption[] {
  const served = (list.models ?? []).map((id): ModelOption => ({ id, served: true }));
  if (!d.model || list.models?.includes(d.model)) return served;
  return [{ id: d.model, served: list.models ? false : null }, ...served];
}

// a Test answer in one line: "250 ms · no speech (silence sent)" / "9 ms · 1 word · “hi”"
export const checkLine = (r: CheckResult): string =>
  r.text.trim() === "" && !r.words.length
    ? `${r.ms} ms · no speech (silence sent)`
    : `${r.ms} ms · ${r.words.length} word${r.words.length === 1 ? "" : "s"} · “${r.text.trim()}”`;
