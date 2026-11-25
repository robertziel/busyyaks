// /settings — Agents & launchers: the launchers (the commands that start an agent session, each one on
// this host's allowlist) and the agent types (what a session is), saved as a new revision of the database's agent
// settings. The server validates (the engine + the allowlist) and its refusal is shown verbatim; Save is refused when
// someone saved in between (409: reload).
import { useEffect, useMemo, useState } from "react";
import { ApiError, apiPost, useResource } from "../api";
import { ErrorState, Loading } from "../components/States";
import { at } from "../lib/format";
import { useTitle } from "../lib/title";
import {
  COLUMN_TYPES,
  fromDraft,
  invocationIndex,
  leadChoices,
  invocationLine,
  newLauncher,
  newType,
  removeLauncher,
  renameLauncher,
  sameDoc,
  toDraft,
  toggleLauncher,
  withInvocation,
  type AgentDoc,
  type AgentSettingsData,
  type Invocation,
  type Draft,
  type Launcher,
  type TypeDraft,
} from "../lib/agentSettings";

const KEY = "/api/settings/agents";

function Checks({
  name,
  all,
  on,
  onChange,
}: {
  name: string;
  all: readonly string[];
  on: string[];
  onChange: (v: string[]) => void;
}) {
  return (
    <span className="as-checks" role="group" aria-label={name}>
      {all.map((v) => (
        <label key={v}>
          <input
            type="checkbox"
            checked={on.includes(v)}
            onChange={(e) => onChange(e.target.checked ? [...on, v] : on.filter((x) => x !== v))}
          />{" "}
          {v}
        </label>
      ))}
    </span>
  );
}

const capOf = (v: string): number | null => (v.trim() === "" ? null : Number(v));

function LauncherRow({
  l,
  commands,
  onChange,
  onRename,
  onRemove,
}: {
  l: Launcher;
  commands: Invocation[];
  onChange: (l: Launcher) => void;
  onRename: (key: string) => void;
  onRemove: () => void;
}) {
  // the launcher IS one of the host's allowlisted invocations (kind, command, args, via shell); only its key and label
  // are the dashboard's. One that matches none (the host list changed since it was saved) is shown, never selectable.
  const at = invocationIndex(commands, l);
  return (
    <fieldset className="as-item">
      <legend>{l.key || "new launcher"}</legend>
      <label>
        key <input value={l.key} onChange={(e) => onRename(e.target.value)} spellCheck={false} />
      </label>
      <label>
        label <input value={l.label} onChange={(e) => onChange({ ...l, label: e.target.value })} />
      </label>
      <label className="as-wide">
        runs (config/busyyaks.yml launch.commands){" "}
        <select
          value={at < 0 ? "off" : String(at)}
          onChange={(e) => onChange(withInvocation(l, commands[Number(e.target.value)]!))}
        >
          {at < 0 && (
            <option value="off" disabled>
              {invocationLine(l)} — not on this host&apos;s allowlist
            </option>
          )}
          {commands.map((c, i) => (
            <option key={i} value={String(i)}>
              {invocationLine(c)}
            </option>
          ))}
        </select>
      </label>
      <button type="button" className="btn small stop-btn" onClick={onRemove}>
        Remove
      </button>
    </fieldset>
  );
}

function TypeCard({
  t,
  launchers,
  types,
  onChange,
  onRemove,
}: {
  t: TypeDraft;
  launchers: string[];
  types: TypeDraft[];
  onChange: (t: TypeDraft) => void;
  onRemove: () => void;
}) {
  return (
    <fieldset className="as-item">
      <legend>{t.label || t.key || "new type"}</legend>
      <label>
        key <input value={t.key} onChange={(e) => onChange({ ...t, key: e.target.value })} spellCheck={false} />
      </label>
      <label>
        label <input value={t.label} onChange={(e) => onChange({ ...t, label: e.target.value })} />
      </label>
      <div className="as-wide">
        launchers{" "}
        <span className="as-checks" role="group" aria-label={`${t.key} launchers`}>
          {launchers.map((k) => (
            <label key={k}>
              <input
                type="checkbox"
                checked={t.launchers.includes(k)}
                onChange={(e) => onChange(toggleLauncher(t, k, e.target.checked))}
              />{" "}
              {k}
            </label>
          ))}
        </span>
      </div>
      {t.launchers.map((k) => (
        <label key={k}>
          model on {k}{" "}
          <input
            value={t.models[k] ?? ""}
            placeholder="Claude Code's own"
            spellCheck={false}
            onChange={(e) => onChange({ ...t, models: { ...t.models, [k]: e.target.value } })}
          />
        </label>
      ))}
      <label title="lead-first boards: a session of this type runs only while the board's lead of that type runs, on its launcher">
        runs under{" "}
        <select value={t.under} onChange={(e) => onChange({ ...t, under: e.target.value })}>
          <option value="">no lead</option>
          {leadChoices(types, t).map((k) => (
            <option key={k} value={k}>
              {k}
            </option>
          ))}
        </select>
      </label>
      <label title="a plain session: runs with no lead, no prompt, adopts nothing">
        <input
          type="checkbox"
          checked={t.standalone}
          onChange={(e) => onChange({ ...t, standalone: e.target.checked })}
        />{" "}
        standalone
      </label>
      <label title="off = the Launch bar never offers it: only its lead's kanban_spawn starts one (a worker for a card)">
        <input
          type="checkbox"
          checked={t.launchable}
          onChange={(e) => onChange({ ...t, launchable: e.target.checked })}
        />{" "}
        on the Launch bar
      </label>
      <label title="the Launch bar button's text; empty = the label">
        button text{" "}
        <input
          value={t.launchLabel}
          placeholder={t.label || "the label"}
          disabled={!t.launchable}
          onChange={(e) => onChange({ ...t, launchLabel: e.target.value })}
        />
      </label>
      <label>
        agent name <input value={t.agent_name} onChange={(e) => onChange({ ...t, agent_name: e.target.value })} />
      </label>
      <label>
        tmux session <input value={t.session_name} onChange={(e) => onChange({ ...t, session_name: e.target.value })} />
      </label>
      <label>
        max{" "}
        <input
          type="number"
          min={0}
          value={t.max ?? ""}
          onChange={(e) => onChange({ ...t, max: capOf(e.target.value) })}
        />
      </label>
      <label>
        max per project{" "}
        <input
          type="number"
          min={0}
          value={t.max_per_project ?? ""}
          onChange={(e) => onChange({ ...t, max_per_project: capOf(e.target.value) })}
        />
      </label>
      <div className="as-wide">
        takes{" "}
        <Checks
          name={`${t.key} takes`}
          all={COLUMN_TYPES}
          on={t.takes}
          onChange={(v) => onChange({ ...t, takes: v })}
        />
      </div>
      <label className="as-wide">
        <span>
          <input
            type="checkbox"
            checked={t.hasPrompt}
            onChange={(e) => onChange({ ...t, hasPrompt: e.target.checked })}
          />{" "}
          prompt · {"{slug} {dir} {session} {agent} {type} {cards}"}
        </span>
        {t.hasPrompt && (
          <textarea
            rows={8}
            value={t.prompt}
            spellCheck={false}
            onChange={(e) => onChange({ ...t, prompt: e.target.value })}
          />
        )}
      </label>
      <button type="button" className="btn small stop-btn" onClick={onRemove}>
        Remove
      </button>
    </fieldset>
  );
}

export function Settings() {
  useTitle("settings");
  const { data, error, loading, reload } = useResource<AgentSettingsData>(KEY);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [base, setBase] = useState<number | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  // the doc the form was built from: the draft is "edited" only when it differs from this
  const [loaded, setLoaded] = useState<AgentDoc | null>(null);
  const dirty = useMemo(
    () => !!draft && !!loaded && !sameDoc(fromDraft(draft), fromDraft(toDraft(loaded))),
    [draft, loaded],
  );

  // a read of a NEWER revision (first load, Reload, another tab's save) becomes the form while nothing is edited;
  // an edited form keeps its edits and shows the stale marker instead
  useEffect(() => {
    if (!data) return;
    if (draft === null || base === null || (!dirty && data.revision.id > base)) {
      setDraft(toDraft(data.doc));
      setBase(data.revision.id);
      setLoaded(data.doc);
    }
  }, [data, draft, base, dirty]);

  if (loading) return <Loading what="agent settings" />;
  if (error && !data) return <ErrorState error={error} what="agent settings" retry={reload} />;
  if (!data || !draft || base === null) return null;

  const stale = data.revision.id > base; // a NEWER revision than the form's (right after a save the cached read is the older one)
  const launcherKeys = draft.launchers.map((l) => l.key);

  const discard = () => {
    setDraft(toDraft(data.doc));
    setBase(data.revision.id);
    setLoaded(data.doc);
    setSaveError(null);
  };
  const save = async () => {
    setSaving(true);
    setSaveError(null);
    try {
      // the form takes the saved revision from the answer itself (the cached read is still the old one until reload)
      const saved = await apiPost<AgentSettingsData>(KEY, { base, doc: fromDraft(draft) });
      setDraft(toDraft(saved.doc));
      setBase(saved.revision.id);
      setLoaded(saved.doc);
      await reload();
    } catch (e) {
      setSaveError(e instanceof ApiError ? `${e.status} · ${e.message}` : String(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <h1>Agents &amp; launchers</h1>
      <p className="muted as-meta">
        revision {data.revision.id} · {data.revision.author} · {at(data.revision.at)} · {data.history.length} kept ·
        allowlist {data.commands.length} invocation{data.commands.length === 1 ? "" : "s"}
        {stale && <b className="as-stale"> · editing revision {base}: a newer one was saved</b>}
      </p>
      {data.error && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>current revision does not run: {data.error}</span>
        </div>
      )}
      <div className="as-bar">
        <button type="button" className="btn primary" disabled={!dirty || saving} onClick={() => void save()}>
          {saving ? "Saving…" : "Save"}
        </button>
        <button type="button" className="btn" disabled={!dirty || saving} onClick={discard}>
          Discard
        </button>
        <button
          type="button"
          className="btn"
          disabled={saving}
          onClick={() => void reload()} // a newer revision then becomes the form unless it is edited (effect above)
        >
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
        <h2>Launchers · {draft.launchers.length}</h2>
        {draft.launchers.map((l, i) => (
          <LauncherRow
            key={i}
            l={l}
            commands={data.commands}
            onChange={(nl) => setDraft({ ...draft, launchers: draft.launchers.map((x, j) => (j === i ? nl : x)) })}
            onRename={(k) => setDraft(renameLauncher(draft, i, k))}
            onRemove={() => setDraft(removeLauncher(draft, i))}
          />
        ))}
        <button
          type="button"
          className="btn small"
          onClick={() => setDraft({ ...draft, launchers: [...draft.launchers, newLauncher(data.commands)] })}
        >
          Add launcher
        </button>
      </section>

      <section className="card as-section">
        <h2>Agent types · {draft.types.length}</h2>
        {draft.types.map((t, i) => (
          <TypeCard
            key={i}
            t={t}
            launchers={launcherKeys}
            types={draft.types}
            onChange={(nt) => setDraft({ ...draft, types: draft.types.map((x, j) => (j === i ? nt : x)) })}
            onRemove={() => setDraft({ ...draft, types: draft.types.filter((_, j) => j !== i) })}
          />
        ))}
        <button
          type="button"
          className="btn small"
          onClick={() => setDraft({ ...draft, types: [...draft.types, newType(draft.launchers)] })}
        >
          Add agent type
        </button>
      </section>

      <section className="card as-section">
        <h2>Commands · revision {data.revision.id}</h2>
        <table className="as-preview">
          <thead>
            <tr>
              <th>type</th>
              <th>launcher</th>
              <th title="bin/launcher runs it inside tmux (bash -ic '…; exec bash', with the session's env) and, when config/busyyaks.yml launch.scopes is set, inside a systemd user scope (systemd-run --user --scope)">
                the agent&apos;s argv · busyyaks adds the skills stage, the board MCP and the prompt · run in tmux, in a
                systemd scope when launch.scopes is set
              </th>
            </tr>
          </thead>
          <tbody>
            {data.preview.map((p) => (
              <tr key={`${p.type}/${p.launcher}`}>
                <td>{p.type}</td>
                <td>{p.launcher}</td>
                <td>
                  <code>{p.argv.join(" ")}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </>
  );
}
