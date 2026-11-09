// Live updates by polling a revision: every `every` ms (tab visible, not paused) GET `revUrl` → {rev}; when it
// differs from the last one seen, call onChange (the caller refetches). Pausing (a drag, unsaved typing) only
// delays: the next poll after it ends catches up. A failed poll is reported, never treated as "no change".
import { useEffect, useRef, useState } from "react";
import { apiGet } from "../api";

export type LiveState = { at: number | null; error: string | null };

// `onRev` gets every poll's whole body (a rev endpoint may carry small live fields beside the rev, e.g. the last scan).
export function useLiveRev<B extends { rev: string } = { rev: string }>(
  revUrl: string | null,
  onChange: () => void,
  opts: { every?: number; paused?: () => boolean; onRev?: (body: B) => void } = {},
): LiveState {
  const every = opts.every ?? 3000;
  const last = useRef<string | null>(null);
  const change = useRef(onChange);
  const paused = useRef(opts.paused);
  const onRev = useRef(opts.onRev);
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
      if (stop || document.hidden || paused.current?.()) return;
      ctl?.abort();
      ctl = new AbortController();
      try {
        const body = await apiGet<B>(revUrl, ctl.signal);
        if (stop) return;
        const rev = body.rev;
        onRev.current?.(body);
        if (last.current !== null && rev !== last.current) change.current();
        last.current = rev;
        setState({ at: Date.now(), error: null });
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
  }, [revUrl, every]);

  return state;
}
