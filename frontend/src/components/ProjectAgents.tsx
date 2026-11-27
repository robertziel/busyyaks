// The project Settings tab's Agent types: the repo's .busyyaks/agents.yml — which opt-in agent types this
// board runs, its own roles (a type + a brief) and which type or role works each column. Shown as a form (the faces in
// their type's colour, a checkbox per opt-in type, a row per role, a select per column) built from what bin/launcher
// loaded; "YAML" edits the file as text (a file the launcher did not read is edited only so). Save = POST …/agents
// {base, text, briefs}: the writer checks it against the agent settings and the board and writes it (+ the new roles'
// briefs, − the dropped roles'); bin/launcher reads it at every launch of a trusted repo. 409 = changed on disk.
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { ApiError, apiGet, apiPost, useResource } from "../api";
import {
  agentsPath,
  columnRows,
  example,
  formBriefs,
  formDrops,
  formOf,
  removeRole,
  renameRole,
  saveBody,
  saveRefusal,
  stateLine,
  toYaml,
  usable,
  who,
  withoutUse,
  worksCards,
  type AgentsForm,
  type NewBrief,
  type ProjectAgentsData,
} from "../lib/projectAgents";
import { AgentFace } from "../vendor/agents_kanban";
import { ErrorState, Loading } from "./States";

function Face({ type, label, size = 22 }: { type: string; label: string; size?: number }) {
  return <AgentFace name={`${type}-sample`} type={type} size={size} title={label} />;
}

function Form({
  d,
  f,
  setF,
  busy,
}: {
  d: ProjectAgentsData;
  f: AgentsForm;
  setF: (f: AgentsForm) => void;
  busy: boolean;
}) {
  const opt = d.types.filter((t) => t.opt_in);
  const always = d.types.filter((t) => !t.opt_in);
  const types = usable(d, f);
  const setRole = (i: number, r: Partial<AgentsForm["roles"][number]>) =>
    setF({ ...f, roles: f.roles.map((x, j) => (j === i ? { ...x, ...r } : x)) });
  return (
    <fieldset className="pa-form" disabled={busy}>
      <section className="pa-block">
        <h3>Types on this board</h3>
        <div className="pa-chips">
          {always.map((t) => (
            <span key={t.key} className="pa-chip on" title="every board runs it">
              <Face type={t.key} label={t.label} /> {t.label} <span className="muted">always</span>
            </span>
          ))}
          {opt.map((t) => {
            const on = f.use.includes(t.key);
            return (
              <label
                key={t.key}
                className={`pa-chip${on ? " on" : ""}`}
                title="opt-in: this board runs it only when ticked"
              >
                <input
                  type="checkbox"
                  checked={on}
                  onChange={(e) => setF(e.target.checked ? { ...f, use: [...f.use, t.key] } : withoutUse(f, t.key))}
                />
                <Face type={t.key} label={t.label} /> {t.label} <span className="muted">opt-in</span>
              </label>
            );
          })}
        </div>
        {opt.length === 0 && (
          <p className="muted pa-note">no opt-in type in the agent settings (Settings → Add preset)</p>
        )}
      </section>

      <section className="pa-block">
        <h3>Roles · this project&apos;s own types</h3>
        <p className="muted pa-note">a role runs as a type, with its brief added to that type&apos;s rules</p>
        {f.roles.map((r, i) => {
          const onDisk = !!d.briefs[r.name.trim()];
          return (
            <div key={i} className="pa-role">
              <Face type={r.like} label={`${r.label || r.name} · runs as ${r.like}`} size={26} />
              <label>
                name
                <input
                  className="mono"
                  value={r.name}
                  spellCheck={false}
                  placeholder="changelog"
                  readOnly={r.disk}
                  title={
                    r.disk
                      ? "its brief is on disk under this name: rename the file in the repo to rename the role"
                      : undefined
                  }
                  onChange={(e) => setF(renameRole(f, i, e.target.value))}
                />
              </label>
              <label>
                label
                <input
                  value={r.label}
                  placeholder="Changelog writer"
                  onChange={(e) => setRole(i, { label: e.target.value })}
                />
              </label>
              <label>
                runs as
                <select value={r.like} onChange={(e) => setRole(i, { like: e.target.value })}>
                  {types.map((t) => (
                    <option key={t.key} value={t.key}>
                      {t.label}
                    </option>
                  ))}
                </select>
              </label>
              <button type="button" className="btn small stop-btn" onClick={() => setF(removeRole(f, i))}>
                Remove
              </button>
              {onDisk ? (
                <p className="muted pa-note pa-wide">
                  brief <code className="mono">.busyyaks/skills/agents/{r.name.trim()}.md</code> · edit it on its card
                  under Agent rules
                </p>
              ) : (
                <textarea
                  className="rc-text mono pa-wide"
                  rows={3}
                  value={r.brief}
                  placeholder={`what a session of this role does — written to .busyyaks/skills/agents/${r.name.trim() || "<name>"}.md`}
                  aria-label={`brief of ${r.name || "the new role"}`}
                  onChange={(e) => setRole(i, { brief: e.target.value })}
                />
              )}
            </div>
          );
        })}
        <button
          type="button"
          className="btn small"
          disabled={types.length === 0}
          onClick={() =>
            setF({
              ...f,
              roles: [...f.roles, { name: "", label: "", like: types[0]?.key ?? "", brief: "", disk: false }],
            })
          }
        >
          Add role
        </button>
      </section>

      <section className="pa-block">
        <h3>Who works each column</h3>
        <table className="pa-columns pa-picks">
          <thead>
            <tr>
              <th>column</th>
              <th>the lead starts</th>
            </tr>
          </thead>
          <tbody>
            {d.columns.map((c) => {
              const name = f.columns[c.key] ?? "";
              const w = name ? who(d, f, name) : null;
              return (
                <tr key={c.key}>
                  <td>
                    {c.label} <span className="muted mono">{c.type}</span>
                  </td>
                  <td>
                    {worksCards(c) ? (
                      <span className="pa-pick">
                        <span className="pa-pick-face">{w && <Face type={w.type} label={w.label} />}</span>
                        <select
                          value={name}
                          aria-label={`who works ${c.label}`}
                          onChange={(e) => setF({ ...f, columns: { ...f.columns, [c.key]: e.target.value } })}
                        >
                          <option value="">any type</option>
                          <optgroup label="types">
                            {types.map((t) => (
                              <option key={t.key} value={t.key}>
                                {t.label}
                              </option>
                            ))}
                          </optgroup>
                          {f.roles.some((r) => r.name.trim()) && (
                            <optgroup label="roles">
                              {f.roles
                                .filter((r) => r.name.trim())
                                .map((r) => (
                                  <option key={r.name} value={r.name.trim()}>
                                    {r.label || r.name} (role · {r.like})
                                  </option>
                                ))}
                            </optgroup>
                          )}
                        </select>
                      </span>
                    ) : (
                      <span className="muted">no session works here</span>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </section>
    </fieldset>
  );
}

export function ProjectAgents({ slug, onUnsaved }: { slug: string; onUnsaved: (n: number) => void }) {
  const key = agentsPath(slug);
  const { data, error, loading, reload } = useResource<ProjectAgentsData>(key);
  const [mode, setMode] = useState<"form" | "yaml">("form");
  const [form, setForm] = useState<AgentsForm | null>(null);
  const [formBase, setFormBase] = useState<string>(""); // the form's text as built: unchanged = nothing to save
  const [text, setText] = useState<string | null>(null);
  const [loadedText, setLoadedText] = useState<string | null>(null);
  const [briefs, setBriefs] = useState<NewBrief[]>([]);
  const [drops, setDrops] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState<{ text: string; tone: string; reload?: boolean } | null>(null);

  const reset = useCallback((d: ProjectAgentsData) => {
    const { form: f } = formOf(d);
    setForm(f);
    setFormBase(f ? toYaml(f) : "");
    setText(d.text ?? "");
    setLoadedText(d.text);
    setBriefs([]);
    setDrops([]);
    setMode(f ? "form" : "yaml");
  }, []);

  // what a save would write: the form's text (the file as loaded while the form is unchanged), or the YAML
  const formText = form && mode === "form" ? toYaml(form) : null;
  const effText = formText !== null ? (formText === formBase ? (loadedText ?? "") : formText) : (text ?? "");
  const effBriefs = form && mode === "form" && data ? formBriefs(form, data) : briefs;
  const effDrops = form && mode === "form" && data ? formDrops(form, data) : drops;
  const unsaved =
    text !== null && (effText !== (loadedText ?? "") || effBriefs.length > 0 || effDrops.length > 0) ? 1 : 0;

  // the first read becomes the form; a newer one only while nothing is edited (read at the new answer, not on each edit)
  const keep = useRef(false);
  keep.current = text !== null && unsaved > 0;
  useEffect(() => {
    if (data && !keep.current) reset(data);
  }, [data, reset]);
  useEffect(() => {
    onUnsaved(unsaved);
    return () => onUnsaved(0);
  }, [unsaved, onUnsaved]);

  if (loading) return <Loading what="agent types" />;
  if (error && !data) return <ErrorState error={error} what="agent types" retry={reload} />;
  if (!data || text === null) return null;

  const line = stateLine(data.launches);
  const { why: formWhy } = formOf(data);
  const refusal = saveRefusal(effText, loadedText, effBriefs, data, effDrops);
  const yamlEdited = text !== (loadedText ?? "") || briefs.length > 0 || drops.length > 0;
  const comments = mode === "form" && unsaved > 0 && /^\s*#/m.test(loadedText ?? "");

  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (refusal || saving) return;
    setSaving(true);
    setStatus(null);
    try {
      const d = await apiPost<ProjectAgentsData>(key, saveBody(effText, data, effBriefs, effDrops));
      reset(d);
      setStatus({ text: `written · ${d.file}`, tone: "ok" });
      await reload();
    } catch (err) {
      const conflict = err instanceof ApiError && err.status === 409;
      setStatus({ text: err instanceof Error ? err.message : String(err), tone: "bad", reload: conflict });
    } finally {
      setSaving(false);
    }
  };
  const loadNewest = async () => {
    try {
      const d = await apiGet<ProjectAgentsData>(key);
      reset(d);
      setStatus(null);
      await reload();
    } catch (err) {
      setStatus({ text: err instanceof Error ? err.message : String(err), tone: "bad", reload: true });
    }
  };
  const toYamlMode = () => {
    setText(effText);
    setBriefs(effBriefs);
    setDrops(effDrops);
    setMode("yaml");
  };
  const setBrief = (i: number, b: NewBrief) => setBriefs(briefs.map((x, j) => (j === i ? b : x)));

  return (
    <form className="pr" onSubmit={(e) => void save(e)} noValidate>
      <div className="pr-bar">
        <h2>Agent types</h2>
        <code className="pr-dir mono" title={data.path}>
          {data.file}
        </code>
        <span className={`pr-scope mono ${line.tone}`} role="status">
          {line.text}
        </span>
      </div>
      <div className="pa-modes" role="tablist" aria-label="edit as">
        <button
          type="button"
          role="tab"
          aria-selected={mode === "form"}
          className={`btn small${mode === "form" ? " on" : ""}`}
          disabled={!form || (mode === "yaml" && yamlEdited)}
          title={
            !form
              ? (formWhy ?? "")
              : mode === "yaml" && yamlEdited
                ? "save or discard the YAML edits first"
                : "checkboxes, roles and a pick per column"
          }
          onClick={() => form && reset(data)}
        >
          Form
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={mode === "yaml"}
          className={`btn small${mode === "yaml" ? " on" : ""}`}
          onClick={toYamlMode}
        >
          YAML
        </button>
        {!form && <span className="muted pa-note">{formWhy}</span>}
      </div>

      {mode === "form" && form ? (
        <Form d={data} f={form} setF={setForm} busy={saving} />
      ) : (
        <>
          <table className="as-preview pa-columns">
            <thead>
              <tr>
                <th>column</th>
                <th>type</th>
                <th>lead starts</th>
              </tr>
            </thead>
            <tbody>
              {columnRows(data).map((r) => (
                <tr key={r.key}>
                  <td>
                    {r.label} <code className="mono">{r.key}</code>
                  </td>
                  <td className="mono">{r.type}</td>
                  <td className="mono">{r.takes}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <textarea
            className="rc-text mono"
            rows={Math.min(24, Math.max(8, text.split("\n").length + 1))}
            value={text}
            readOnly={saving || !!data.error}
            spellCheck={false}
            placeholder={example(data)}
            aria-label={data.file}
            onChange={(e) => setText(e.target.value)}
          />
          {briefs.map((b, i) => (
            <div key={i} className="pr-new">
              <input
                className="mono"
                value={b.role}
                placeholder="role"
                aria-label="new role's name"
                onChange={(e) => setBrief(i, { ...b, role: e.target.value })}
              />
              <textarea
                className="rc-text mono"
                rows={4}
                value={b.body}
                placeholder="what a session of this role does (agents/<role>.md)"
                aria-label={`brief of ${b.role || "the new role"}`}
                onChange={(e) => setBrief(i, { ...b, body: e.target.value })}
              />
              <button type="button" className="btn small" onClick={() => setBriefs(briefs.filter((_, j) => j !== i))}>
                Drop
              </button>
            </div>
          ))}
          {data.roles.length > 0 && (
            <p className="pr-global">
              a role dropped from the file takes its brief with it:{" "}
              {data.roles.map((r) => (
                <label key={r} className="mono">
                  <input
                    type="checkbox"
                    checked={drops.includes(r)}
                    onChange={(e) => setDrops(e.target.checked ? [...drops, r] : drops.filter((x) => x !== r))}
                  />{" "}
                  remove {r}&apos;s brief{" "}
                </label>
              ))}
            </p>
          )}
          <button type="button" className="btn small" onClick={() => setBriefs([...briefs, { role: "", body: "" }])}>
            Brief for a new role
          </button>
        </>
      )}

      {mode === "form" && effDrops.length > 0 && (
        <p className="pr-global warn">
          removed with its role: {effDrops.map((r) => `.busyyaks/skills/agents/${r}.md`).join(", ")}
        </p>
      )}
      {comments && <p className="pr-global warn">saving from the form rewrites the file: its comments go</p>}
      <div className="pr-actions">
        <button className="btn primary" disabled={!!refusal || saving} aria-describedby="pa-why">
          {saving ? "Saving…" : effText.trim() === "" && loadedText !== null ? "Save · removes the file" : "Save"}
        </button>
        <button type="button" className="btn small" disabled={!unsaved || saving} onClick={() => reset(data)}>
          Discard
        </button>
        <span id="pa-why" className={`pr-status ${status?.tone ?? (refusal ? "muted" : "ok")}`} role="status">
          {status?.text ?? refusal ?? "ready to save"}
        </span>
        {status?.reload && (
          <button type="button" className="btn small" onClick={() => void loadNewest()}>
            Load newest (drops edits)
          </button>
        )}
      </div>
    </form>
  );
}
