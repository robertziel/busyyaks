// /settings/updates — Updates (card 536): this checkout vs config/busyyaks.yml updates (the launcher's last check),
// the newest release tag and the followed branch with an Update button each, and the running / last update step by
// step. The update runs on the host (`bin/yaks update`, started by the launcher); while it restarts the web the page
// keeps polling and says it is reconnecting. Every refusal is the launcher's, shown as is.
import { useEffect, useState } from "react";
import { ApiError, apiPost, useResource } from "../api";
import { ErrorState, Loading } from "../components/States";
import { useTitle } from "../lib/title";
import { pollEvery, progress, rows, short, STEP_LABEL, STEPS, type Row, type UpdateStatus } from "../lib/updates";

const KEY = "/api/settings/update";
const when = (iso: string | undefined) => (iso ? new Date(iso).toLocaleString() : "—");

function TargetRow({ row, busy, onUpdate }: { row: Row; busy: boolean; onUpdate: (r: Row) => void }) {
  return (
    <tr className={`up-row ${row.state}`}>
      <th scope="row">{row.label}</th>
      <td>
        <b>{row.name}</b> <span className="mono">{short(row.sha)}</span>
      </td>
      <td>
        <span className={`tag up-state ${row.state}`}>{row.detail}</span>
      </td>
      <td className="up-act">
        <button
          type="button"
          className="btn small primary"
          disabled={!!row.blocked || busy}
          title={row.blocked ?? `update to ${row.name}`}
          onClick={() => onUpdate(row)}
        >
          Update to {row.name}
        </button>
        {row.blocked && row.state === "available" && <span className="up-why">{row.blocked}</span>}
      </td>
    </tr>
  );
}

function Steps({ s }: { s: UpdateStatus }) {
  const r = s.last;
  const p = progress(r);
  if (!r || !p) return null;
  return (
    <section className={`card up-run ${r.state}`} aria-labelledby="up-run-h">
      <div className="up-run-head">
        <h2 id="up-run-h">
          {r.state === "running" || r.state === "starting"
            ? "Updating"
            : r.state === "done"
              ? "Last update"
              : r.state === "interrupted"
                ? "Last update interrupted"
                : "Last update failed"}
        </h2>
        <b role="status">
          {short(r.from)} → {r.name ?? "—"} {short(r.to)} · {p.index}/{p.total}
        </b>
      </div>
      <ol className="up-steps">
        {STEPS.map((step, i) => {
          const st =
            r.state === "done" || i < p.index
              ? "ok"
              : i === p.index
                ? r.state === "failed" || r.state === "interrupted"
                  ? "bad"
                  : "now"
                : "todo";
          return (
            <li key={step} className={st}>
              {STEP_LABEL[step]}
            </li>
          );
        })}
      </ol>
      {r.error && <p className="flash bad up-error">{r.error}</p>}
      <dl className="up-facts">
        <div>
          <dt>started</dt>
          <dd>{when(r.started_at)}</dd>
        </div>
        <div>
          <dt>ended</dt>
          <dd>{when(r.done_at)}</dd>
        </div>
        {r.backup && (
          <div>
            <dt>backup</dt>
            <dd className="mono">{r.backup}</dd>
          </div>
        )}
        {r.log && (
          <div>
            <dt>log</dt>
            <dd className="mono">{r.log}</dd>
          </div>
        )}
      </dl>
    </section>
  );
}

export function UpdateSettings() {
  useTitle("updates");
  const [down, setDown] = useState(false);
  const [every, setEvery] = useState(pollEvery(undefined, false));
  const { data, error, loading, reload } = useResource<UpdateStatus>(KEY, {
    every,
  });
  const [action, setAction] = useState<string | null>(null);
  const [refusal, setRefusal] = useState<string | null>(null);
  // the web restarts during an update: a failed poll while one ran (the cache keeps the last answer) is
  // "reconnecting", not an error; the next good answer ends it
  const running = !!data?.running;
  useEffect(() => {
    setDown(!!error && (running || down));
  }, [error, running, down]);
  const reconnecting = down;
  // fast polls while it runs / checks / reconnects (the hook re-arms on a new interval)
  useEffect(() => {
    setEvery(pollEvery(data, down));
  }, [data, down]);

  const post = async (body: Record<string, string>, what: string) => {
    setAction(what);
    setRefusal(null);
    try {
      await apiPost(KEY, body);
    } catch (e) {
      setRefusal(e instanceof ApiError ? `${e.status} · ${e.message}` : String(e));
    } finally {
      setAction(null);
      await reload();
    }
  };
  const onUpdate = (r: Row) => {
    if (!r.sha) return;
    if (!window.confirm(`Update this checkout to ${r.name} (${short(r.sha)}) and restart the stack?`)) return;
    void post({ step: "apply", mode: r.mode, sha: r.sha }, "apply");
  };

  if (loading) return <Loading what="updates" />;
  if (!data && error) return <ErrorState error={error} what="updates" retry={reload} />;
  if (!data) return null;
  const c = data.check;
  const busy = !!action || data.running;

  return (
    <div className="up">
      <h1>Updates</h1>
      <p className="muted up-meta mono">
        {data.settings.remote} · tags {data.settings.tags} · branch {data.settings.branch} · channel{" "}
        {data.settings.channel} · every {data.settings.check_minutes} min
      </p>
      {reconnecting && (
        <p className="flash warn" role="status">
          <i className="dot" /> reconnecting · the stack is restarting
        </p>
      )}
      {refusal && (
        <p className="flash bad" role="alert">
          <i className="dot bad" /> {refusal}
        </p>
      )}
      {data.check_error && (
        <p className="flash bad" role="alert">
          <i className="dot bad" /> check {when(data.check_error.at)}: {data.check_error.error}
        </p>
      )}
      <section className="card up-now" aria-labelledby="up-now-h">
        <div className="up-run-head">
          <h2 id="up-now-h">Checkout</h2>
          <button
            type="button"
            className="btn small"
            disabled={busy || data.checking}
            onClick={() => void post({ step: "check" }, "check")}
          >
            {data.checking || action === "check" ? "Checking…" : "Check now"}
          </button>
        </div>
        {c ? (
          <dl className="up-facts">
            <div>
              <dt>HEAD</dt>
              <dd>
                <b className="mono">{short(c.head.sha)}</b> {c.head.branch ? `on ${c.head.branch}` : "detached"} ·{" "}
                <span className="mono">{c.head.describe}</span>
              </dd>
            </div>
            <div>
              <dt>from</dt>
              <dd className="mono">{c.url}</dd>
            </div>
            <div>
              <dt>checked</dt>
              <dd>{when(c.checked_at)}</dd>
            </div>
            {c.dirty.length > 0 && (
              <div>
                <dt>changed</dt>
                <dd className="mono">{c.dirty.join(" · ")}</dd>
              </div>
            )}
            {c.ignored_tags.length > 0 && (
              <div>
                <dt>not versions</dt>
                <dd className="mono">{c.ignored_tags.join(" · ")}</dd>
              </div>
            )}
          </dl>
        ) : (
          <p className="muted">{data.checking ? "checking…" : "not checked yet"}</p>
        )}
      </section>
      {c && (
        <section className="card up-targets" aria-label="Update targets">
          <div className="up-scroll">
            <table className="up-table">
              <tbody>
                {rows(data).map((r) => (
                  <TargetRow key={r.mode} row={r} busy={busy} onUpdate={onUpdate} />
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
      <Steps s={data} />
    </div>
  );
}
