// /settings/runtime — Runtime: the services' timing (scan, writer sync, GitHub collection and PR polls, the
// notifier's loops, the watchdog's grace), saved as a new revision of the database's runtime settings; every service
// reads it at its next turn. The page: the watch period against the CI poll window as a meter, the keys grouped by
// service (seconds + the duration in words + the .env name each replaced), Save / Discard with the reason Save is off,
// the revisions kept. The server validates; its refusal is shown verbatim at the field it names, else beside Save.
// Someone saved in between (409) → the newer revision is offered, the edits stay until it is loaded.
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ApiError, apiPost, useResource } from "../api";
import { ErrorState, Loading } from "../components/States";
import { ago, at } from "../lib/format";
import { useTitle } from "../lib/title";
import {
  changedKeys,
  fieldRefusal,
  fromDraft,
  groups,
  human,
  refusedKey,
  saveRefusal,
  toDraft,
  rebase,
  WATCH_PARTS,
  watchFigure,
  type Conflict,
  type Draft,
  type RuntimeSettingsData,
  type WatchFigure,
} from "../lib/runtimeSettings";

const KEY = "/api/settings/runtime";
const pct = (share: number) => `${Math.round(share * 1000) / 10}%`;

// the watch period drawn on the CI poll window: the bar is the longer of the two, the tick is where the window ends
function Watch({ fig, doc }: { fig: WatchFigure | null; doc: Draft }) {
  const state = fig ? (fig.ok ? "ok" : "over") : "na";
  return (
    <section className={`card rt-watch ${state}`} aria-labelledby="rt-watch-h">
      <div className="rt-watch-head">
        <h2 id="rt-watch-h">Watch pass · CI poll window</h2>
        <b className="rt-verdict" id="rt-verdict" role="status">
          {fig
            ? fig.ok
              ? `ok · ${pct(fig.period / fig.window)} · ${human(fig.spare)} spare`
              : fig.spare === 0
                ? `${fig.period} s = window · must be < ${fig.window} s`
                : `over · +${human(-fig.spare)} · must be < ${fig.window} s`
            : "—"}
        </b>
      </div>
      <div
        className="rt-meter"
        role="img"
        aria-label={fig ? `watch period ${fig.period} s, CI poll window ${fig.window} s` : "not computed"}
      >
        {fig && <i className="rt-fill" style={{ width: pct(fig.fill) }} />}
        {fig && fig.mark < 1 && <i className="rt-mark" style={{ left: pct(fig.mark) }} />}
      </div>
      <dl className="rt-terms">
        <div>
          <dt>watch period</dt>
          <dd>
            <b>{fig ? `${fig.period} s` : "—"}</b>
            <span className="mono">
              {doc.notifier_watch_seconds || "—"} ÷ {doc.notifier_interval_seconds || "—"} rounded up ×{" "}
              {doc.notifier_interval_seconds || "—"}
            </span>
          </dd>
        </div>
        <div>
          <dt>CI poll window</dt>
          <dd>
            <b>{fig ? `${fig.window} s` : "—"}</b>
            <span className="mono">10 × {doc.github_ci_interval_seconds || "—"}</span>
          </dd>
        </div>
      </dl>
    </section>
  );
}

export function RuntimeSettings() {
  useTitle("runtime settings");
  const { data, error, loading, refreshing, reload } = useResource<RuntimeSettingsData>(KEY);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [loadedFrom, setLoadedFrom] = useState<RuntimeSettingsData | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [savedId, setSavedId] = useState<number | null>(null);
  const [conflicts, setConflicts] = useState<Record<string, Conflict>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [wantRebase, setWantRebase] = useState(false); // Reload / a 409 asked for the newest revision under the edits

  // the form moves onto a newer revision: its changed keys kept, the rest taken from it (lib rebase); only setters
  // inside, so one function for the component's life
  const rebaseOnto = useCallback((newest: RuntimeSettingsData, from: RuntimeSettingsData, mine: Draft) => {
    const r = rebase(mine, toDraft(from), toDraft(newest));
    const kept = changedKeys(r.draft, toDraft(newest)).length;
    const n = Object.keys(r.conflicts).length;
    setDraft(r.draft);
    setLoadedFrom(newest);
    setConflicts(r.conflicts);
    setSaveError(null);
    setSavedId(null);
    setNotice(
      kept ? `rev ${from.revision.id} → ${newest.revision.id} · ${kept} kept${n ? ` · ${n} in conflict` : ""}` : null,
    );
  }, []);

  // the first read becomes the form; a NEWER one becomes it while nothing is edited, or when Reload / a 409 asked —
  // an edited form nobody asked to move keeps its base, and Save stays off until it is rebased or discarded
  useEffect(() => {
    if (!data) return;
    if (draft === null || !loadedFrom) {
      setDraft(toDraft(data));
      setLoadedFrom(data);
      return;
    }
    const newer = data.revision.id > loadedFrom.revision.id;
    const dirty = changedKeys(draft, toDraft(loadedFrom)).length > 0;
    if (newer && (!dirty || wantRebase)) {
      rebaseOnto(data, loadedFrom, draft);
      setWantRebase(false);
    } else if (wantRebase && !refreshing) setWantRebase(false);
  }, [data, draft, loadedFrom, wantRebase, refreshing, rebaseOnto]);

  if (loading) return <Loading what="runtime settings" />;
  if (error && !data) return <ErrorState error={error} what="runtime settings" retry={reload} />;
  if (!data || !draft || !loadedFrom) return null;

  const loaded = toDraft(loadedFrom);
  const base = loadedFrom.revision.id;
  const stale = data.revision.id > base;
  const keys = Object.keys(data.keys);
  const changed = changedKeys(draft, loaded);
  const dirty = changed.length > 0;
  const fig = watchFigure(fromDraft(draft));
  const refusal = saveRefusal(draft, loaded, data.min, data.max, stale ? data.revision.id : undefined);
  const errorKey = saveError ? refusedKey(saveError, keys) : null;
  const edit = (k: string, v: string) => {
    setDraft({ ...draft, [k]: v });
    setSaveError(null);
    setSavedId(null);
    setNotice(null);
  };
  const discard = () => {
    if (!dirty || saving) return;
    setDraft(toDraft(data));
    setLoadedFrom(data);
    setConflicts({});
    setSaveError(null);
    setSavedId(null);
    setNotice(null);
  };
  const reloadNow = () => {
    if (saving) return;
    setWantRebase(true);
    void reload();
  };
  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (refusal || saving) return;
    setSaving(true);
    setSaveError(null);
    setNotice(null);
    try {
      const saved = await apiPost<RuntimeSettingsData>(KEY, { base, doc: fromDraft(draft) });
      setDraft(toDraft(saved));
      setLoadedFrom(saved);
      setConflicts({});
      setSavedId(saved.revision.id);
      await reload();
    } catch (err) {
      setSaveError(err instanceof ApiError ? `${err.status} · ${err.message}` : String(err));
      if (err instanceof ApiError && err.status === 409) {
        setWantRebase(true); // someone saved in between: the newest revision under these edits
        await reload();
      }
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="rt">
      <h1>
        Runtime <span className="tag mono">rev {base}</span>
      </h1>
      <p className="muted rt-meta">
        {loadedFrom.revision.author} · {at(loadedFrom.revision.at)} · {data.revisions} kept ·{" "}
        <span className="nowrap">
          {data.min}–{data.max} s
        </span>
      </p>
      {stale && (
        <div className="flash warn" role="status">
          <i className="dot" />
          <span>
            editing rev {base} · rev {data.revision.id} saved by {data.revision.author} {at(data.revision.at)}
          </span>
          <button type="button" className="btn small" onClick={() => rebaseOnto(data, loadedFrom, draft)}>
            Keep {changed.length} on rev {data.revision.id}
          </button>
        </div>
      )}

      <form onSubmit={(e) => void save(e)} noValidate>
        <Watch fig={fig} doc={draft} />

        <section className="card rt-groups">
          {groups(data.keys).map((g) => (
            <div key={g.fields[0]!.key} className="rt-group" role="group" aria-label={g.service || undefined}>
              <h3>{g.service}</h3>
              <div className="rt-rows">
                {g.fields.map(({ key, label, env }) => {
                  const id = `rt-${key}`;
                  const value = draft[key]!;
                  const bad = fieldRefusal(value, data.min, data.max);
                  const isChanged = changed.includes(key);
                  const fromServer = errorKey === key ? saveError : null;
                  const overWatch = !!fig && !fig.ok && key in WATCH_PARTS; // one of the three the refused figure is made of
                  const invalid = !!bad || !!fromServer || overWatch;
                  const c = conflicts[key];
                  const conflict = c && value.trim() === c.mine ? c : null;
                  const described = [
                    `${id}-h`,
                    `${id}-n`,
                    fromServer && `${id}-e`,
                    conflict && `${id}-c`,
                    overWatch && "rt-verdict",
                  ];
                  return (
                    <div key={key} className={`rt-row${isChanged ? " changed" : ""}${invalid ? " bad" : ""}`}>
                      <div className="rt-name">
                        <label htmlFor={id}>{label}</label>
                        {WATCH_PARTS[key] && <span className="tag rt-part">{WATCH_PARTS[key]}</span>}
                        <code className="rt-env" title={`was .env ${env}`}>
                          {env}
                        </code>
                      </div>
                      <span className="rt-input">
                        <input
                          id={id}
                          name={key}
                          value={value}
                          onChange={(e) => edit(key, e.target.value)}
                          readOnly={saving} // a value typed during the POST would be replaced by the saved revision
                          inputMode="numeric"
                          autoComplete="off"
                          spellCheck={false}
                          aria-invalid={invalid || undefined}
                          aria-describedby={described.filter(Boolean).join(" ")}
                        />
                        <span aria-hidden="true">s</span>
                      </span>
                      <span className="rt-human" id={`${id}-h`}>
                        {bad ? "—" : human(Number(value))}
                      </span>
                      <span className="rt-note" id={`${id}-n`} aria-live="polite">
                        {bad && <span className="rt-bad">{bad}</span>}
                        {isChanged && (
                          <button
                            type="button"
                            className="rt-was"
                            onClick={() => {
                              edit(key, loaded[key]!);
                              document.getElementById(id)?.focus(); // this chip leaves with the change
                            }}
                            aria-label={`was ${loaded[key]} s, revert ${label}`}
                          >
                            was {loaded[key]} s ↺
                          </button>
                        )}
                      </span>
                      {conflict && (
                        <span className="rt-msg rt-warn" id={`${id}-c`} role="status">
                          rev {base} set {conflict.theirs} s · yours {conflict.mine} s
                        </span>
                      )}
                      {fromServer && (
                        <span className="rt-msg rt-bad" id={`${id}-e`} role="alert">
                          {fromServer}
                        </span>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          ))}
        </section>

        <div className="rt-bar">
          {/* aria-disabled, not disabled: Save stays in the Tab order and says why it is off (its description) */}
          <button
            type="submit"
            className="btn primary"
            aria-disabled={!!refusal || saving || undefined}
            aria-describedby="rt-status"
          >
            {saving ? "Saving…" : dirty && !stale ? `Save ${changed.length} as rev ${base + 1}` : "Save"}
          </button>
          <button type="button" className="btn" aria-disabled={!dirty || saving || undefined} onClick={discard}>
            Discard
          </button>
          <button type="button" className="btn" aria-disabled={saving || undefined} onClick={reloadNow}>
            Reload
          </button>
          <span id="rt-status" className="rt-status" aria-live="polite">
            {refusal && refusal !== "no changes" ? (
              <span className="rt-bad">{refusal}</span>
            ) : savedId !== null && !dirty ? (
              <span className="rt-ok">saved · rev {savedId}</span>
            ) : notice ? (
              <span className="rt-warn">{notice}</span>
            ) : (
              <span className="muted">{refusal ?? `${changed.length} changed`}</span>
            )}
          </span>
        </div>
        {saveError && !errorKey && (
          <div className="flash bad" role="alert">
            <i className="dot bad" />
            <span>{saveError}</span>
          </div>
        )}
      </form>

      <section className="card rt-history" aria-labelledby="rt-history-h">
        <h2 id="rt-history-h">
          History · {data.revisions}
          {data.revisions > data.history.length && ` · newest ${data.history.length}`}
        </h2>
        <ol className="rt-revs">
          {data.history.map((h) => (
            <li key={h.id} className={h.id === base ? "current" : undefined} aria-current={h.id === base || undefined}>
              <b className="mono">{h.id}</b>
              <span className="rt-who">{h.author}</span>
              <time className="mono" dateTime={new Date(h.at * 1000).toISOString()}>
                {at(h.at)}
              </time>
              <span className="muted mono">{ago(h.at)}</span>
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}
