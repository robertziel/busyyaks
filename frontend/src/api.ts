// The JSON API client and a small stale-while-revalidate cache: a route renders what it has at once and
// refreshes in the background. Errors are the server's {error} with its status — shown, never papered over.
import { useCallback, useEffect, useSyncExternalStore } from "react";
import { signOutTarget } from "./lib/signOut";

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function meta(name: string): string {
  const el = document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`);
  if (!el) throw new Error(`missing <meta name="${name}">`);
  return el.content;
}
export const csrfToken = (): string => meta("csrf-token");
export const userEmail = (): string => meta("user-email");
// where "Sign out" posts, or null when the auth provider has no session to end (provider none)
export const signOutPath = (): string | null => signOutTarget(meta("sign-out"));

async function parse<T>(r: Response): Promise<T> {
  if (r.status === 401) {
    // back to this page after sign-in (the server validates next)
    window.location.assign("/login?next=" + encodeURIComponent(window.location.pathname + window.location.search));
    throw new ApiError(401, "not signed in");
  }
  const text = await r.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    throw new ApiError(r.status, `HTTP ${r.status}: not JSON`);
  }
  if (!r.ok) {
    const msg = body && typeof body === "object" && "error" in body ? String(body.error) : `HTTP ${r.status}`;
    throw new ApiError(r.status, msg);
  }
  return body as T;
}

export async function apiGet<T>(path: string, signal?: AbortSignal): Promise<T> {
  return parse<T>(await fetch(path, { credentials: "same-origin", headers: { Accept: "application/json" }, signal }));
}

export async function apiPost<T>(path: string, body: unknown): Promise<T> {
  return parse<T>(
    await fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
      body: JSON.stringify(body),
    }),
  );
}

export async function apiDelete<T>(path: string): Promise<T> {
  return parse<T>(
    await fetch(path, {
      method: "DELETE",
      credentials: "same-origin",
      headers: { Accept: "application/json", "X-CSRF-Token": csrfToken() },
    }),
  );
}

// Multipart upload with progress (fetch cannot report upload progress). Same errors as the JSON calls: the server's
// {error} with its status; a network failure is status 0 with the reason.
export function apiUpload<T>(path: string, form: FormData, onProgress?: (fraction: number) => void): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", path);
    xhr.withCredentials = true;
    xhr.setRequestHeader("Accept", "application/json");
    xhr.setRequestHeader("X-CSRF-Token", csrfToken());
    if (onProgress) xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total);
    xhr.onerror = () => reject(new ApiError(0, "network error: the upload did not reach the server"));
    xhr.onabort = () => reject(new ApiError(0, "upload aborted"));
    xhr.onload = () => {
      // a proxy in front (nginx client_max_body_size) answers 413 in HTML, before the app sees the file
      if (xhr.status === 413 && !(xhr.getResponseHeader("Content-Type") ?? "").includes("json"))
        return reject(
          new ApiError(413, "the proxy in front of busyyaks refused the upload as too large (its body size limit)"),
        );
      parse<T>(new Response(xhr.responseText || null, { status: xhr.status })).then(resolve, reject);
    };
    xhr.send(form);
  });
}

// ── cache ────────────────────────────────────────────────────────────────────────────────────────
type Entry = { data?: unknown; error?: ApiError; at: number; inflight?: Promise<void> };
const cache = new Map<string, Entry>();
const listeners = new Map<string, Set<() => void>>();

function notify(key: string) {
  listeners.get(key)?.forEach((cb) => cb());
}

// Never rejects: a failed read is stored as the entry's error (useResource → error), so callers may `void` it.
export function revalidate(key: string): Promise<void> {
  const cur = cache.get(key);
  if (cur?.inflight) return cur.inflight;
  const inflight = apiGet<unknown>(key).then(
    (data) => {
      cache.set(key, { data, at: Date.now() });
      notify(key);
    },
    (err: unknown) => {
      const e = err instanceof ApiError ? err : new ApiError(0, err instanceof Error ? err.message : String(err));
      cache.set(key, { data: cur?.data, error: e, at: Date.now() });
      notify(key);
    },
  );
  cache.set(key, { ...(cur ?? { at: 0 }), inflight });
  notify(key);
  return inflight;
}

// Drop + refetch every cached key under a prefix (after a mutation).
export function invalidate(prefix: string) {
  for (const key of cache.keys()) if (key.startsWith(prefix)) void revalidate(key);
}

export type Resource<T> = {
  data: T | undefined;
  error: ApiError | undefined;
  loading: boolean; // nothing to show yet
  refreshing: boolean;
  reload: () => Promise<void>; // never rejects: a failure lands in `error`
};

export function useResource<T>(key: string | null, opts: { every?: number } = {}): Resource<T> {
  const subscribe = useCallback(
    (cb: () => void) => {
      if (!key) return () => {};
      const set = listeners.get(key) ?? new Set<() => void>();
      set.add(cb);
      listeners.set(key, set);
      return () => {
        set.delete(cb);
      };
    },
    [key],
  );
  const snapshot = useCallback(() => (key ? cache.get(key) : undefined), [key]);
  const entry = useSyncExternalStore(subscribe, snapshot, snapshot);
  const every = opts.every;

  useEffect(() => {
    if (!key) return;
    void revalidate(key);
    if (!every) return;
    const tick = () => {
      if (!document.hidden) void revalidate(key);
    };
    const id = window.setInterval(tick, every);
    document.addEventListener("visibilitychange", tick);
    return () => {
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", tick);
    };
  }, [key, every]);

  const reload = useCallback(() => (key ? revalidate(key) : Promise.resolve()), [key]);
  return {
    data: entry?.data as T | undefined,
    error: entry?.error,
    loading: !!key && entry?.data === undefined && !entry?.error,
    refreshing: !!entry?.inflight,
    reload,
  };
}
