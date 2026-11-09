// "Clear idle": stop agent tmux sessions that are not working. The preview comes from the host (only agent
// sessions; never attached, waiting, busy or with subagents running); every row is a checkbox, all on; the
// host re-checks each against a fresh snapshot before it stops it and reports what it skipped and why.
import { useEffect, useRef, useState } from "react";
import { ApiError, apiGet, apiPost, invalidate } from "../api";
import { ago } from "../lib/format";
import type { ReapPreview, ReapResult } from "../types";

const key = (c: { name: string; socket: string }) => `${c.socket}/${c.name}`;

export function ReapButton() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        className="btn small reap-btn"
        onClick={() => setOpen(true)}
        title="Stop agent sessions that are not working"
      >
        Clear idle
      </button>
      {open && <ReapDialog onClose={() => setOpen(false)} />}
    </>
  );
}

function ReapDialog({ onClose }: { onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const [preview, setPreview] = useState<ReapPreview | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<ReapResult[] | null>(null);

  useEffect(() => {
    ref.current?.showModal();
    apiGet<ReapPreview>("/api/agents/reap").then(
      (p) => {
        setPreview(p);
        setPicked(new Set(p.candidates.map(key)));
      },
      (e: unknown) => setErr(e instanceof ApiError ? e.message : String(e)),
    );
  }, []);

  const stop = async () => {
    if (!preview) return;
    setBusy(true);
    setErr(null);
    try {
      const sessions = preview.candidates
        .filter((c) => picked.has(key(c)))
        .map((c) => ({ name: c.name, socket: c.socket }));
      const r = await apiPost<{ results: ReapResult[] }>("/api/agents/reap", { sessions });
      setResults(r.results);
      invalidate("/api/agents");
      invalidate("/api/projects");
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const n = picked.size;
  return (
    <dialog ref={ref} className="reap-dialog" onClose={onClose} aria-labelledby="reap-h">
      <header>
        <h3 id="reap-h">Clear idle agent sessions</h3>
        <button type="button" className="btn small" onClick={() => ref.current?.close()}>
          Close
        </button>
      </header>
      {err && (
        <p className="ag-err">
          <i className="dot bad" /> {err}
        </p>
      )}
      {!preview && !err && <p className="muted">reading the collector…</p>}
      {results ? (
        <>
          <p className="reap-sum">
            <b className="ok">{results.filter((r) => r.stopped).length}</b> stopped ·{" "}
            <b>{results.filter((r) => !r.stopped).length}</b> kept
          </p>
          <ul className="reap-list">
            {results.map((r) => (
              <li key={r.name} className={r.stopped ? "done" : "kept"}>
                <i className={`dot ${r.stopped ? "ok" : "bad"}`} /> <b>{r.name}</b>{" "}
                <span className="muted">{r.stopped ? `stopped · ${r.reason}` : r.reason}</span>
              </li>
            ))}
          </ul>
        </>
      ) : (
        preview && (
          <>
            <p className="reap-sum">
              <b>{preview.candidates.length}</b> not working · kept: working, waiting for you, attached, subagents
              running, quiet &lt; {preview.quiet_min} min when state is unreadable
            </p>
            {preview.candidates.length === 0 ? (
              <p className="muted">0 sessions to clear</p>
            ) : (
              <>
                <label className="reap-all">
                  <input
                    type="checkbox"
                    checked={n === preview.candidates.length}
                    onChange={(e) => setPicked(e.target.checked ? new Set(preview.candidates.map(key)) : new Set())}
                  />
                  all {preview.candidates.length}
                </label>
                <ul className="reap-list">
                  {preview.candidates.map((c) => (
                    <li key={key(c)}>
                      <label>
                        <input
                          type="checkbox"
                          checked={picked.has(key(c))}
                          onChange={(e) =>
                            setPicked((p) => {
                              const s = new Set(p);
                              if (e.target.checked) s.add(key(c));
                              else s.delete(key(c));
                              return s;
                            })
                          }
                        />
                        <b>{c.name}</b>
                        <span className="muted">
                          {[c.project, c.engines.join("·"), c.title].filter(Boolean).join(" · ")}
                        </span>
                        <em>
                          {c.reason} · active {ago(c.activity)} ago
                        </em>
                        {c.cards && c.cards.length > 0 && (
                          <em className="reap-owns">
                            owns {c.cards.map((k) => `#${k.id} ${k.title}`).join(", ")} — stopping it releases{" "}
                            {c.cards.length === 1 ? "that card" : "those cards"}
                          </em>
                        )}
                      </label>
                    </li>
                  ))}
                </ul>
                <footer>
                  <button type="button" className="btn small" onClick={() => ref.current?.close()}>
                    Cancel
                  </button>
                  <button type="button" className="btn danger" disabled={busy || n === 0} onClick={() => void stop()}>
                    {busy ? "Stopping…" : `Stop ${n} session${n === 1 ? "" : "s"}`}
                  </button>
                </footer>
              </>
            )}
          </>
        )
      )}
    </dialog>
  );
}
