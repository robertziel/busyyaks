// localStorage that never throws (private mode), plus a subscribable so every control sharing a key stays in sync.
import { useCallback, useSyncExternalStore } from "react";

export function get(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function set(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* private mode */
  }
  listeners.get(key)?.forEach((cb) => cb());
}

export function getJSON<T>(key: string, fallback: T): T {
  const raw = get(key);
  if (raw == null) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

const listeners = new Map<string, Set<() => void>>();

export function useStored(key: string): [string | null, (v: string) => void] {
  const subscribe = useCallback(
    (cb: () => void) => {
      const s = listeners.get(key) ?? new Set<() => void>();
      s.add(cb);
      listeners.set(key, s);
      return () => {
        s.delete(cb);
      };
    },
    [key],
  );
  const value = useSyncExternalStore(
    subscribe,
    () => get(key),
    () => null,
  );
  const update = useCallback((v: string) => set(key, v), [key]);
  return [value, update];
}
