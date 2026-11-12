// /settings/daily-report — Daily report: how the daily report runs (schedule, cutoff, timeouts, gateway,
// models, runner), saved as a new revision of the database's daily report settings. The runner is one of this host's
// allowlisted entries (config/busyyaks.yml daily_report_runners); the server validates and its refusal is shown
// verbatim; Save is refused when someone saved in between (409: reload).
import { useEffect, useMemo, useState } from "react";
import { ApiError, apiPost, useResource } from "../api";
import { ErrorState, Loading } from "../components/States";
import { at } from "../lib/format";
import { useTitle } from "../lib/title";
import {
  FIELDS,
  entryLine,
  fromDraft,
  hasRunner,
  pickRunner,
  sameDoc,
  toDraft,
  type DailyReportSettingsData,
  type Draft,
} from "../lib/dailyReportSettings";

const KEY = "/api/settings/daily-report";

export function DailyReportSettings() {
  useTitle("daily report settings");
  const { data, error, loading, reload } = useResource<DailyReportSettingsData>(KEY);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [base, setBase] = useState<number | null | undefined>(undefined); // undefined = not loaded; null = none saved
  const [loadedFrom, setLoadedFrom] = useState<DailyReportSettingsData | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const dirty = useMemo(
    () => !!draft && !!loadedFrom && !sameDoc(fromDraft(loadedFrom, draft), fromDraft(loadedFrom, toDraft(loadedFrom))),
    [draft, loadedFrom],
  );

  // a read of a NEWER revision becomes the form while nothing is edited; an edited form keeps its edits
  useEffect(() => {
    if (!data) return;
    const id = data.revision?.id ?? null;
    if (draft === null || base === undefined || (!dirty && (id ?? 0) > (base ?? 0))) {
      setDraft(toDraft(data));
      setBase(id);
      setLoadedFrom(data);
    }
  }, [data, draft, base, dirty]);

  if (loading) return <Loading what="daily report settings" />;
  if (error && !data) return <ErrorState error={error} what="daily report settings" retry={reload} />;
  if (!data || !draft || base === undefined || !loadedFrom) return null;

  const stale = (data.revision?.id ?? 0) > (base ?? 0);
  const discard = () => {
    setDraft(toDraft(data));
    setBase(data.revision?.id ?? null);
    setLoadedFrom(data);
    setSaveError(null);
  };
  const save = async () => {
    setSaving(true);
    setSaveError(null);
    try {
      const saved = await apiPost<DailyReportSettingsData>(KEY, {
        base,
        doc: fromDraft(loadedFrom, draft),
      });
      setDraft(toDraft(saved));
      setBase(saved.revision?.id ?? null);
      setLoadedFrom(saved);
      await reload();
    } catch (e) {
      setSaveError(e instanceof ApiError ? `${e.status} · ${e.message}` : String(e));
    } finally {
      setSaving(false);
    }
  };
  const field = (k: keyof Draft["fields"], v: string) => setDraft({ ...draft, fields: { ...draft.fields, [k]: v } });

  return (
    <>
      <h1>Daily report</h1>
      <p className="muted as-meta">
        {data.revision
          ? `revision ${data.revision.id} · ${data.revision.author} · ${at(data.revision.at)} · ${data.revisions} kept`
          : "never saved"}{" "}
        · allowlist {data.runners.length} runner
        {data.runners.length === 1 ? "" : "s"}
        {stale && <b className="as-stale"> · editing revision {base}: a newer one was saved</b>}
      </p>
      {data.error && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>not configured: {data.error}</span>
        </div>
      )}
      <div className="as-bar">
        <button
          type="button"
          className="btn primary"
          disabled={(!dirty && base !== null) || !hasRunner(draft) || saving}
          onClick={() => void save()}
        >
          {saving ? "Saving…" : "Save"}
        </button>
        <button type="button" className="btn" disabled={!dirty || saving} onClick={discard}>
          Discard
        </button>
        <button type="button" className="btn" disabled={saving} onClick={() => void reload()}>
          Reload
        </button>
        {dirty && <span className="muted">unsaved changes</span>}
      </div>
      {saveError && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>{saveError}</span>
        </div>
      )}

      <section className="card as-section">
        <h2>Run</h2>
        <fieldset className="as-item">
          <legend>schedule · gateway · models</legend>
          {FIELDS.map(([k, hint]) => (
            <label key={k} className="as-wide" title={hint}>
              {k}{" "}
              <input
                value={draft.fields[k]}
                onChange={(e) => field(k, e.target.value)}
                spellCheck={false}
                placeholder={hint}
                inputMode={k === "probe_timeout" || k === "context_length" ? "numeric" : undefined}
              />
            </label>
          ))}
        </fieldset>
      </section>

      <section className="card as-section">
        <h2>Runner</h2>
        <fieldset className="as-item">
          <legend>{draft.runner >= 0 ? data.runners[draft.runner]!.type : (draft.saved?.type ?? "none")}</legend>
          <label className="as-wide">
            runs (config/busyyaks.yml daily_report_runners){" "}
            <select
              value={draft.runner < 0 ? "off" : String(draft.runner)}
              onChange={(e) => setDraft(pickRunner(data, draft, Number(e.target.value)))}
            >
              {draft.runner < 0 && (
                <option value="off" disabled>
                  {draft.saved
                    ? `${String(draft.saved.type)} — not on this host's allowlist`
                    : data.runners.length
                      ? "pick a runner"
                      : "no runner on this host's allowlist"}
                </option>
              )}
              {data.runners.map((r, i) => (
                <option key={i} value={String(i)}>
                  {entryLine(r)}
                </option>
              ))}
            </select>
          </label>
          {Object.keys(draft.extra).map((k) => (
            <label key={k} className="as-wide">
              {k}{" "}
              <input
                value={draft.extra[k]}
                onChange={(e) =>
                  setDraft({
                    ...draft,
                    extra: { ...draft.extra, [k]: e.target.value },
                  })
                }
                inputMode="numeric"
                spellCheck={false}
              />
            </label>
          ))}
        </fieldset>
      </section>

      {data.history.length > 0 && (
        <section className="card as-section">
          <h2>
            History · {data.revisions}
            {data.revisions > data.history.length && ` · newest ${data.history.length}`}
          </h2>
          <table className="as-preview">
            <thead>
              <tr>
                <th>revision</th>
                <th>author</th>
                <th>saved</th>
              </tr>
            </thead>
            <tbody>
              {data.history.map((h) => (
                <tr key={h.id}>
                  <td>{h.id}</td>
                  <td>{h.author}</td>
                  <td>{at(h.at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}
