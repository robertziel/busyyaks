// Stop / Stop all on a project's tmux sessions. The operator confirms, the host kills exactly the named
// sessions of THIS project (POST /api/projects/*slug/stop) whatever they are doing — unlike "Clear idle", which only
// stops sessions that are not working. Each session's result is shown; nothing is reported stopped that was not.
import { useState } from "react";
import { apiPost, invalidate } from "../api";
import { useFlash } from "./Flash";

type StopResult = { name: string; stopped: boolean; reason: string; registration?: string };

export function useStopSessions(slug: string, onDone: () => void) {
  const { setFlash } = useFlash();
  const [busy, setBusy] = useState<string | null>(null); // a session name, or "*" for all
  const stop = async (names: string[], what: string) => {
    if (names.length === 0) return;
    if (
      !window.confirm(
        `Stop ${names.length} tmux session${names.length > 1 ? "s" : ""} of ${slug}? Any work in progress there is killed.\n\n${names.join("\n")}`,
      )
    )
      return;
    setBusy(what);
    try {
      const path = `/api/projects/${slug.split("/").map(encodeURIComponent).join("/")}/stop`;
      const r = await apiPost<{ results: StopResult[] }>(path, { sessions: names });
      const ok = r.results.filter((x) => x.stopped);
      const bad = r.results.filter((x) => !x.stopped);
      setFlash({
        ok: bad.length === 0,
        text: [
          ok.length ? `stopped ${ok.map((x) => x.name).join(", ")}` : "",
          ...bad.map((x) => `${x.name}: ${x.reason}`),
        ]
          .filter(Boolean)
          .join(" · "),
      });
    } catch (e) {
      setFlash({ ok: false, text: `stop failed: ${e instanceof Error ? e.message : String(e)}` });
    } finally {
      setBusy(null);
      invalidate("/api/agents");
      invalidate("/api/projects");
      onDone();
    }
  };
  return { busy, stop };
}

export function StopButton({
  label,
  title,
  busy,
  disabled,
  onClick,
}: {
  label: string;
  title: string;
  busy: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <button type="button" className="btn small stop-btn" title={title} disabled={disabled} onClick={onClick}>
      {busy ? "Stopping…" : label}
    </button>
  );
}
