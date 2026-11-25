// /settings/agent-rules — Agent rules: busyyaks's OWN skills layers, i.e. every global markdown a session busyyaks
// launches gets (GET /api/settings/agent-rules, read by bin/launcher from the checkout it launches from). Top: the agent
// types — what each is (its purpose, from the agent settings) and the files its entry skill holds, in launch order.
// Then one full-width card per FILE, grouped by who gets it (every session · per agent type · on demand · this
// deployment), each editable: Save → POST {files: {path: {base, body}}} → the writer service writes the checkout (the
// launch's own checks first; 409 = changed on disk, 422 = refused, verbatim). The files are tracked in the busyyaks
// repo: a save leaves an uncommitted change, said with the list — never a commit.
import { useEffect, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { ApiError, apiGet, apiPost, useResource } from "../api";
import { RuleCard } from "../components/RuleCard";
import { ErrorState, Loading } from "../components/States";
import {
  anchor,
  budget,
  bytes,
  changedPaths,
  changes,
  editedWhere,
  fieldRefusal,
  gitTag,
  groups,
  openSet,
  purpose,
  RULES_PATH,
  role,
  saveRefusal,
  SOURCE_LABEL,
  stripFront,
  toDraft,
  toggleOpen,
  typeTitle,
  uncommitted,
  what,
  whoGets,
  type AgentRulesData,
  type Draft,
} from "../lib/agentRules";
import { useTitle } from "../lib/title";

type Form = { loaded: AgentRulesData; draft: Draft };

// the agent types and the order their entry skill holds the files
export function TypesTable({ data }: { data: AgentRulesData }) {
  const all = data.agent_types;
  return (
    <section className="card ar-types" aria-labelledby="ar-types-h">
      <h2 id="ar-types-h">What each session gets, in launch order</h2>
      <ol className="ar-type-list">
        {all.map((t) => (
          <li key={t.key} className={`ar-type ${role(t, all)}`}>
            <div className="ar-type-head">
              <b className="ar-type-name">{typeTitle(t)}</b>
              <code className="ar-type-key">{t.key}</code>
              <span className="ar-type-purpose">{purpose(t, all)}</span>
              <span className="ar-type-bytes mono" title="core + agents files: the entry skill busyyaks stages">
                {(t.start_bytes ?? 0).toLocaleString("en-US")} / {data.limits.max_start_bytes.toLocaleString("en-US")} B
              </span>
            </div>
            <ol className="ar-order">
              {(t.start ?? []).map((p) => (
                <li key={p}>
                  <a href={`#${anchor(p)}`} className="mono">
                    {p}
                  </a>
                </li>
              ))}
              <li className="muted">
                + this project&apos;s <code>.busyyaks/skills/agents/{t.key}.md</code> — adds, or with{" "}
                <code>mode: replace</code> replaces the agents files above; a project skill of a name here replaces it
                (project page → Settings)
              </li>
            </ol>
            {(t.on_demand ?? []).length > 0 && (
              <p className="ar-ondemand muted">
                on demand, when the work needs it:{" "}
                {(t.on_demand ?? []).map((s, i) => (
                  <span key={s}>
                    {i > 0 && ", "}
                    <code>{s}</code>
                  </span>
                ))}
              </p>
            )}
          </li>
        ))}
      </ol>
    </section>
  );
}

export function AgentRulesView({
  data,
  form,
  open,
  saving,
  status,
  onLoadNewest = null,
  onToggle,
  onChange,
}: {
  data: AgentRulesData;
  form: Form;
  open: string[];
  saving: boolean;
  status: { tone: string; text: string };
  onLoadNewest?: (() => void) | null; // a 409: the files on disk moved — load them (drops the edits)
  onToggle: (id: string) => void;
  onChange: (path: string, v: string) => void;
}) {
  const { loaded, draft } = form;
  const changed = changedPaths(draft, loaded);
  const dirty = uncommitted(data);
  return (
    <>
      <div className="ar-bar">
        <h1>Agent rules</h1>
        <span className="ar-checkout mono" title={data.checkout.host}>
          {data.checkout.host}
        </span>
        <span className="muted ar-scope">busyyaks-launched sessions only · read at every launch</span>
      </div>
      {!data.checkout.mount && (
        <div className="flash bad" role="status">
          <i className="dot" />
          <span>read-only here · {data.checkout.error}</span>
        </div>
      )}
      {dirty && (
        <div className="flash warn" role="status">
          <i className="dot" />
          <span>
            {dirty.text} · {dirty.paths.join(" · ")}
          </span>
        </div>
      )}
      {data.git_error && data.checkout.mount && (
        <div className="flash bad" role="status">
          <i className="dot" />
          <span>git state unknown · {data.git_error}</span>
        </div>
      )}
      <TypesTable data={data} />
      {groups(loaded).map((g) => (
        <section key={g.key} className="ar-group" aria-labelledby={`ar-g-${g.key}`}>
          <header className="ar-group-head">
            <h2 id={`ar-g-${g.key}`}>{g.title}</h2>
            <span className="muted">{g.note}</span>
          </header>
          {g.files.map((f) => {
            const id = anchor(f.path);
            const value = draft[f.path] ?? "";
            const isChanged = changed.includes(f.path);
            const b = budget({ ...f, body: value }, loaded);
            return (
              <RuleCard
                key={f.path}
                id={id}
                path={f.path}
                what={what(f, loaded.agent_types)}
                who={whoGets(f, loaded.agent_types)}
                source={SOURCE_LABEL[f.source]}
                where={editedWhere(f)}
                size={{ n: f.kind === "core" ? bytes(stripFront(value)) : bytes(value), max: b.max, tip: b.tip }}
                git={gitTag(f.git, isChanged)}
                value={value}
                html={f.html}
                changed={isChanged}
                refusal={isChanged ? fieldRefusal(f, value, loaded) : null}
                error={f.error}
                readOnly={saving || !data.checkout.mount}
                open={open.includes(id)}
                onToggle={() => onToggle(id)}
                onChange={(v) => onChange(f.path, v)}
              />
            );
          })}
        </section>
      ))}
      <div className="ar-actions">
        <button className="btn primary" disabled={!!saveRefusal(draft, loaded) || saving} aria-describedby="ar-why">
          {saving ? "Saving…" : changed.length ? `Save ${changed.length}` : "Save"}
        </button>
        <span id="ar-why" className={`ar-status ${status.tone}`} role="status">
          {status.text}
        </span>
        {onLoadNewest && (
          <button type="button" className="btn small" onClick={onLoadNewest}>
            Load newest (drops edits)
          </button>
        )}
      </div>
      <p className="muted ar-foot">
        A project adds its own <code>.busyyaks/skills/agents/&lt;type&gt;.md</code> on its page →{" "}
        <Link to="/projects">Projects</Link> → Settings.
      </p>
    </>
  );
}

export function AgentRulesSettings() {
  useTitle("agent rules");
  const { data, error, loading, reload } = useResource<AgentRulesData>(RULES_PATH);
  const [form, setForm] = useState<Form | null>(null);
  const [open, setOpen] = useState<string[]>(() => openSet());
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<{ status: number; text: string } | null>(null);
  const [saved, setSaved] = useState<string[] | null>(null);

  // the first read becomes the form; a newer one only while nothing is edited
  useEffect(() => {
    if (!data) return;
    setForm((f) => (!f || changedPaths(f.draft, f.loaded).length === 0 ? { loaded: data, draft: toDraft(data) } : f));
  }, [data]);
  // a link to one file (#rule-…) opens its card
  useEffect(() => {
    const id = window.location.hash.slice(1);
    if (id.startsWith("rule-")) setOpen((o) => (o.includes(id) ? o : [...o, id]));
  }, []);

  if (loading) return <Loading what="agent rules" />;
  if (error && !data) return <ErrorState error={error} what="agent rules" retry={reload} />;
  if (!data || !form) return null;

  const refusal = saveRefusal(form.draft, form.loaded);
  const status = saveError
    ? {
        tone: "bad",
        text:
          saveError.status === 409
            ? `conflict · ${saveError.text}`
            : saveError.status === 422
              ? `refused · ${saveError.text}`
              : `${saveError.status || "no answer"} · ${saveError.text}`,
      }
    : saved
      ? { tone: "ok", text: `written · ${saved.join(", ")} · read at the next launch · not committed` }
      : { tone: "muted", text: refusal ?? "" };
  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (refusal || saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      const names = changedPaths(form.draft, form.loaded);
      const next = await apiPost<AgentRulesData>(RULES_PATH, { files: changes(form.draft, form.loaded) });
      setForm({ loaded: next, draft: toDraft(next) });
      setSaved(names);
      await reload();
    } catch (err) {
      setSaveError(
        err instanceof ApiError ? { status: err.status, text: err.message } : { status: 0, text: String(err) },
      );
    } finally {
      setSaving(false);
    }
  };
  const loadNewest = async () => {
    try {
      const fresh = await apiGet<AgentRulesData>(RULES_PATH);
      setForm({ loaded: fresh, draft: toDraft(fresh) });
      setSaveError(null);
      await reload();
    } catch (err) {
      setSaveError(
        err instanceof ApiError ? { status: err.status, text: err.message } : { status: 0, text: String(err) },
      );
    }
  };
  return (
    <form className="ar" onSubmit={(e) => void save(e)} noValidate>
      <AgentRulesView
        data={data}
        form={form}
        open={open}
        saving={saving}
        status={status}
        onLoadNewest={saveError?.status === 409 ? () => void loadNewest() : null}
        onToggle={(id) => setOpen((o) => toggleOpen(id, o))}
        onChange={(p, v) => {
          setForm({ loaded: form.loaded, draft: { ...form.draft, [p]: v } });
          setSaveError(null);
          setSaved(null);
        }}
      />
    </form>
  );
}
