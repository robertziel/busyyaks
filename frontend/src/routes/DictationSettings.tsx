// /settings/dictation — Dictation (card 634): what the card dialog's mic runs, in three cards — the switch, the speech
// server (URL + Connect, the write-only token) and the model (picked from what that server's GET /v1/models lists,
// Test beside it) with its two limits — saved as a new revision by the one Save bar; the next recording uses it, no
// restart. The token field is empty and says whether one is saved; a new URL needs its token typed (or No token).
// Connect = the typed server's models, Test = one second of silence through the form's server + model; nothing saved
// by either. The server validates; its refusal is shown verbatim. Someone saved in between (409) → Load rev N.
import { useEffect, useState, type FormEvent } from "react";
import { ApiError, apiPost, useResource } from "../api";
import { ErrorState, Loading } from "../components/States";
import { ago, at } from "../lib/format";
import { useTitle } from "../lib/title";
import {
  adopts,
  changedKeys,
  checkLine,
  checkRefusal,
  connectRefusal,
  fieldRefusal,
  fromDraft,
  LABELS,
  modelOptions,
  modelsFor,
  modelsLine,
  saveRefusal,
  server,
  toDraft,
  tokenLine,
  tokenPlaceholder,
  type CheckResult,
  type DictationData,
  type Draft,
  type Models,
  type Probe,
} from "../lib/dictationSettings";

const KEY = "/api/settings/dictation";
const SECONDS = [
  ["timeout_seconds", LABELS.timeout_seconds, "per transcription request"],
  ["max_seconds", LABELS.max_seconds, "longer recordings are refused"],
] as const;

const errText = (err: unknown) => (err instanceof ApiError ? `${err.status} · ${err.message}` : String(err));

export function DictationSettings() {
  useTitle("dictation settings");
  const { data, error, loading, reload } = useResource<DictationData>(KEY);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [loadedFrom, setLoadedFrom] = useState<DictationData | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedId, setSavedId] = useState<number | null>(null);
  const [checking, setChecking] = useState(false);
  const [check, setCheck] = useState<{ ok: boolean; line: string } | null>(null);
  const [probe, setProbe] = useState<Probe | null>(null);
  const [connecting, setConnecting] = useState(false);

  // the first read becomes the form; a newer one replaces it only while nothing is edited (adopts)
  useEffect(() => {
    if (data && adopts(data, draft, loadedFrom)) {
      setDraft(toDraft(data));
      setLoadedFrom(data);
    }
  }, [data, draft, loadedFrom]);

  if (loading) return <Loading what="dictation settings" />;
  if (error && !data) return <ErrorState error={error} what="dictation settings" retry={reload} />;
  if (!data || !draft || !loadedFrom) return null;

  const loaded = toDraft(loadedFrom);
  const base = loadedFrom.revision?.id ?? null;
  const newest = data.revision?.id ?? null;
  const stale = newest !== base;
  const changed = changedKeys(draft, loaded);
  const dirty = changed.length > 0;
  const list = modelsFor(draft, loaded, data, probe);
  const refusal = saveRefusal(draft, loaded, data, list, stale && newest !== null ? newest : undefined);
  const testOff = checkRefusal(draft, loaded, list, data.limits);
  const connectOff = connectRefusal(draft, loaded);
  const options = modelOptions(draft, list);
  const edit = (patch: Partial<Draft>) => {
    setDraft((d) => (d ? { ...d, ...patch } : d));
    setSaveError(null);
    setSavedId(null);
    setCheck(null);
  };
  const discard = () => {
    if (!dirty || saving) return;
    setDraft(toDraft(data));
    setLoadedFrom(data);
    setSaveError(null);
  };
  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (refusal || saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      const saved = await apiPost<DictationData>(KEY, {
        base,
        doc: fromDraft(draft),
      });
      setDraft(toDraft(saved));
      setLoadedFrom(saved);
      setSavedId(saved.revision?.id ?? null);
      await reload();
    } catch (err) {
      setSaveError(errText(err));
      if (err instanceof ApiError && err.status === 409) await reload();
    } finally {
      setSaving(false);
    }
  };
  const runCheck = async () => {
    if (testOff || checking) return;
    setChecking(true);
    setCheck(null);
    try {
      const r = await apiPost<CheckResult>(`${KEY}/test`, {
        doc: fromDraft(draft),
      });
      setCheck({ ok: true, line: `${draft.model} · ${checkLine(r)}` });
    } catch (err) {
      setCheck({ ok: false, line: errText(err) });
    } finally {
      setChecking(false);
    }
  };
  const connect = async () => {
    if (connectOff || connecting) return;
    const s = server(draft);
    setConnecting(true);
    try {
      const r = await apiPost<Models>(`${KEY}/models`, s);
      setProbe({ ...s, ...r });
    } catch (err) {
      setProbe({ ...s, models: null, models_error: errText(err) });
    } finally {
      setConnecting(false);
    }
  };

  const mic = loadedFrom.doc?.enabled;
  const status = modelsLine(list, connecting, connectOff);
  const notServed = options.some((o) => o.id === draft.model && o.served === false);
  const cls = (key: keyof Draft, bad = false) =>
    `dic-row${changed.includes(key) ? " changed" : ""}${bad ? " bad" : ""}`;
  const was = (key: keyof Draft) =>
    changed.includes(key) && key !== "token" && loaded[key] !== "" ? (
      <span className="dic-was">was {String(loaded[key])}</span>
    ) : null;
  return (
    <div className="dic">
      <div className="dic-head">
        <h1>Dictation</h1>
        <b className={`dic-pill${mic ? " ok" : ""}`}>{mic ? `on · ${loadedFrom.doc?.model}` : "off"}</b>
      </div>
      <p className="muted dic-meta">
        {loadedFrom.revision
          ? `rev ${loadedFrom.revision.id} · ${loadedFrom.revision.author} · ${ago(loadedFrom.revision.at)} ago`
          : "never saved · the mic is off"}
      </p>
      {!loadedFrom.revision && (
        <ol className="card dic-steps" aria-label="first setup">
          <li>type the speech server&apos;s URL (and its token, if it needs one), press Connect</li>
          <li>pick a model, press Test</li>
          <li>set both limits, switch the mic on, Save</li>
        </ol>
      )}
      {stale && (
        <div className="flash warn" role="status">
          <i className="dot" />
          <span>
            rev {newest} saved by {data.revision?.author} while you edit {base === null ? "no revision" : `rev ${base}`}
          </span>
          <button type="button" className="btn small" onClick={() => (setDraft(toDraft(data)), setLoadedFrom(data))}>
            Load rev {newest}
          </button>
        </div>
      )}

      <form className="dic-form" onSubmit={(e) => void save(e)} noValidate>
        <section className={`card dic-switch-card${changed.includes("enabled") ? " changed" : ""}`}>
          <label className="dic-switch-row" htmlFor="dic-enabled">
            <span className="dic-switch-text">
              <b>Mic in card comments</b>
              <small>speech typed into a card&apos;s comment box, transcribed by the server below</small>
            </span>
            <span className="dic-switch-state">{draft.enabled ? "On" : "Off"}</span>
            <input
              id="dic-enabled"
              type="checkbox"
              role="switch"
              className="dic-switch"
              checked={draft.enabled}
              disabled={saving}
              onChange={(e) => edit({ enabled: e.target.checked })}
            />
          </label>
        </section>

        <section className="card dic-sec" aria-labelledby="dic-server-h">
          <h2 id="dic-server-h">Speech server</h2>
          <div className={cls("url")}>
            <label htmlFor="dic-url">URL</label>
            <div className="dic-field">
              <div className="dic-inline">
                <input
                  id="dic-url"
                  type="url"
                  className="dic-wide"
                  autoComplete="off"
                  spellCheck={false}
                  placeholder="http://host:8000"
                  value={draft.url}
                  readOnly={saving}
                  aria-describedby="dic-url-n dic-models-n"
                  onChange={(e) => edit({ url: e.target.value })}
                />
                <button
                  type="button"
                  className="btn"
                  aria-disabled={!!connectOff || connecting || undefined}
                  title={connectOff ?? "read the models this server lists · nothing is saved"}
                  onClick={() => void connect()}
                >
                  {connecting ? "Connecting…" : "Connect"}
                </button>
              </div>
              <small id="dic-url-n">any OpenAI-compatible speech-to-text server {was("url")}</small>
            </div>
          </div>
          <div className={cls("token")}>
            <label htmlFor="dic-token">Token</label>
            <div className="dic-field">
              <div className="dic-inline">
                <input
                  id="dic-token"
                  type="password"
                  className="dic-wide"
                  autoComplete="new-password"
                  spellCheck={false}
                  placeholder={tokenPlaceholder(draft, loadedFrom.doc)}
                  value={draft.token ?? ""}
                  readOnly={saving}
                  aria-describedby="dic-token-n"
                  onChange={(e) =>
                    edit({ token: e.target.value === "" && loaded.token === null ? null : e.target.value })
                  }
                />
                {draft.token !== "" && !!(loadedFrom.doc?.token_set || draft.token) && (
                  <button type="button" className="btn" disabled={saving} onClick={() => edit({ token: "" })}>
                    No token
                  </button>
                )}
                {draft.token !== null && loadedFrom.doc?.token_set && (
                  <button type="button" className="btn" disabled={saving} onClick={() => edit({ token: null })}>
                    Keep saved
                  </button>
                )}
              </div>
              <small id="dic-token-n">
                {tokenLine(draft, loadedFrom.doc)}
                {draft.token !== null && loadedFrom.doc?.token_set && (
                  <span className="dic-warn"> · the old token stays in History: revoke it on the server</span>
                )}
              </small>
            </div>
          </div>
          <p id="dic-models-n" className={`dic-line ${status.tone}`} role="status" aria-live="polite">
            <i className="dot" />
            {status.text}
          </p>
        </section>

        <section className="card dic-sec" aria-labelledby="dic-model-h">
          <h2 id="dic-model-h">Model</h2>
          <div className={cls("model", notServed)}>
            <label htmlFor="dic-model">Model</label>
            <div className="dic-field">
              <div className="dic-inline">
                <select
                  id="dic-model"
                  className="dic-wide"
                  value={draft.model}
                  disabled={saving}
                  aria-describedby="dic-check"
                  onChange={(e) => edit({ model: e.target.value })}
                >
                  <option value="">{options.length ? "pick a model" : "connect to list models"}</option>
                  {options.map((o) => (
                    <option key={o.id} value={o.id}>
                      {o.served ? o.id : o.served === null ? `${o.id} · connect to check` : `${o.id} · not served`}
                    </option>
                  ))}
                </select>
                <button
                  type="button"
                  className="btn"
                  aria-disabled={!!testOff || checking || undefined}
                  title={testOff ?? "send 1 s of silence through this model · nothing is saved"}
                  onClick={() => void runCheck()}
                >
                  {checking ? "Testing…" : "Test"}
                </button>
              </div>
              <small id="dic-check" aria-live="polite">
                {check ? (
                  <span className={check.ok ? "dic-ok" : "dic-bad"}>
                    {check.ok ? "✓ " : "✗ "}
                    {check.line}
                  </span>
                ) : testOff ? (
                  <>Test · {testOff}</>
                ) : (
                  <>Test sends 1 s of silence through the model · nothing is saved</>
                )}{" "}
                {was("model")}
              </small>
            </div>
          </div>
          {SECONDS.map(([key, label, about]) => {
            // an empty field is not red before anything is typed (first setup): the Save bar still says what is missing
            const bad = draft[key].trim() === "" ? null : fieldRefusal(draft[key], data.limits[key]);
            const [min, max] = data.limits[key];
            return (
              <div key={key} className={cls(key, !!bad)}>
                <label htmlFor={`dic-${key}`}>{label}</label>
                <div className="dic-field">
                  <div className="dic-inline">
                    <input
                      id={`dic-${key}`}
                      type="text"
                      className="dic-num"
                      inputMode="numeric"
                      autoComplete="off"
                      spellCheck={false}
                      value={draft[key]}
                      readOnly={saving}
                      aria-invalid={!!bad || undefined}
                      aria-describedby={`dic-${key}-n`}
                      onChange={(e) => edit({ [key]: e.target.value })}
                    />
                    <span className="dic-unit">seconds</span>
                  </div>
                  <small id={`dic-${key}-n`}>
                    {bad ? <span className="dic-bad">{bad}</span> : `${about} · ${min}–${max}`} {was(key)}
                  </small>
                </div>
              </div>
            );
          })}
        </section>

        <div className={`card dic-actions${dirty ? " dirty" : ""}`}>
          {/* aria-disabled, not disabled: the buttons stay in the Tab order and say why they are off */}
          <button
            type="submit"
            className="btn primary"
            aria-disabled={!!refusal || saving || undefined}
            aria-describedby="dic-status"
          >
            {saving ? "Saving…" : dirty && !stale && !refusal ? `Save as rev ${(newest ?? 0) + 1}` : "Save"}
          </button>
          <button type="button" className="btn" aria-disabled={!dirty || saving || undefined} onClick={discard}>
            Discard
          </button>
          <span id="dic-status" className="dic-status" aria-live="polite">
            {saveError ? (
              <span className="dic-bad">{saveError}</span>
            ) : refusal && refusal !== "no changes" ? (
              <span className="dic-bad">{refusal}</span>
            ) : savedId !== null && !dirty ? (
              <span className="dic-ok">✓ saved as rev {savedId} · the next recording uses it</span>
            ) : (
              <span className="muted">
                {dirty ? `${changed.length} unsaved change${changed.length === 1 ? "" : "s"}` : "no changes"}
              </span>
            )}
          </span>
        </div>
      </form>

      <details className="card dic-history">
        <summary>
          History · {data.revisions} revision{data.revisions === 1 ? "" : "s"}
          {data.revisions > data.history.length && ` · newest ${data.history.length}`}
        </summary>
        {data.history.length ? (
          <ol className="dic-revs">
            {data.history.map((h) => (
              <li
                key={h.id}
                className={h.id === base ? "current" : undefined}
                aria-current={h.id === base || undefined}
              >
                <b className="mono">{h.id}</b>
                <span className="dic-who">{h.author}</span>
                <time className="mono" dateTime={new Date(h.at * 1000).toISOString()}>
                  {at(h.at)}
                </time>
                <span className="muted mono">{ago(h.at)}</span>
              </li>
            ))}
          </ol>
        ) : (
          <span className="muted">none saved yet</span>
        )}
      </details>
    </div>
  );
}
