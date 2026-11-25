// Live updates by polling a revision: every `every` ms (tab visible, not paused) GET `revUrl` → {rev}; when it
// differs from the last one SHOWN, call onChange (the caller refetches). Pausing (a drag, unsaved typing) only
// delays: the next poll after it ends catches up. A failed poll is reported, never treated as "no change".
// A revision counts as shown only once onChange settled: one that rejects (the refetch failed) leaves the last shown
// revision, so the next poll refetches again, and its error is the live state's ("refresh failed: …") — never a page
// that silently keeps old data under a green live mark (the engine's useLiveRev has the same rule).
import { useEffect, useRef, useState } from "react";
import { apiGet } from "../api";

// A poll runs while the tab is visible; `whileHidden` polls a hidden tab too (the waiting widget: a card that starts
// waiting there marks the tab, card 611). A pause (a drag, unsaved typing) skips the poll either way.
export const shouldPoll = (hidden: boolean, whileHidden: boolean, paused: boolean): boolean =>
  (!hidden || whileHidden) && !paused;

export type LiveState = { at: number | null; error: string | null };

// One poll's answer: `rev` after `shown` → the revision now shown + the poll's error (null = in sync).
export async function takeRev(
  shown: string | null,
  rev: string,
  onChange: () => void | Promise<unknown>,
): Promise<{ shown: string | null; error: string | null }> {
  if (shown === null || rev === shown) return { shown: rev, error: null };
  try {
    await onChange();
  } catch (e) {
    return { shown, error: `refresh failed: ${e instanceof Error ? e.message : String(e)}` };
  }
  return { shown: rev, error: null };
}

// A live poll's onChange from a reload that resolves to its outcome (null = landed, else its error or message):
// rejects with that error, so takeRev asks the refresh again on the next poll.
export function refreshed(reload: () => Promise<Error | string | null>): () => Promise<void> {
  return async () => {
    const e = await reload();
    if (e) throw e instanceof Error ? e : new Error(e);
  };
}

// `onRev` gets every poll's whole body (a rev endpoint may carry small live fields beside the rev, e.g. the last scan).
export function useLiveRev<B extends { rev: string } = { rev: string }>(
  revUrl: string | null,
  onChange: () => void | Promise<unknown>,
  opts: { every?: number; paused?: () => boolean; onRev?: (body: B) => void; whileHidden?: boolean } = {},
): LiveState {
  const every = opts.every ?? 3000;
  const last = useRef<string | null>(null);
  const change = useRef(onChange);
  const paused = useRef(opts.paused);
  const onRev = useRef(opts.onRev);
  const whileHidden = opts.whileHidden ?? false;
  onRev.current = opts.onRev;
  change.current = onChange;
  paused.current = opts.paused;
  const [state, setState] = useState<LiveState>({ at: null, error: null });

  useEffect(() => {
    if (!revUrl) return;
    last.current = null;
    let stop = false;
    let ctl: AbortController | null = null;
    const tick = async () => {
      if (stop || !shouldPoll(document.hidden, whileHidden, paused.current?.() ?? false)) return;
      ctl?.abort();
      ctl = new AbortController();
      try {
        const body = await apiGet<B>(revUrl, ctl.signal);
        if (stop) return;
        const rev = body.rev;
        onRev.current?.(body);
        const out = await takeRev(last.current, rev, change.current);
        if (stop) return;
        last.current = out.shown;
        if (out.error) setState((s) => ({ ...s, error: out.error }));
        else setState({ at: Date.now(), error: null });
      } catch (e) {
        if (!stop && !(e instanceof DOMException && e.name === "AbortError"))
          setState((s) => ({ ...s, error: e instanceof Error ? e.message : String(e) }));
      }
    };
    void tick();
    const id = window.setInterval(() => void tick(), every);
    const vis = () => void tick();
    document.addEventListener("visibilitychange", vis);
    return () => {
      stop = true;
      ctl?.abort();
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", vis);
    };
  }, [revUrl, every, whileHidden]);

  return state;
}
