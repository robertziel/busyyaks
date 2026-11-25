// A project's Settings tab (/projects/<slug>?tab=settings): EVERY file of the repo's own `.busyyaks/skills/`, one card
// each — per agent type its agents/<type>.md (adds to the global rules of the type, or replaces them: the mode
// switch writes the file's `mode: replace` frontmatter), then the project's on-demand skills (a global skill's name
// replaces that skill for this project: "Override" starts from its text) with their reference files; files are made
// and removed here (Write / Preview through the server's POST /api/markdown). Save = POST …/agent-rules {files: {path:
// {base, body}}}: the writer service checks the layer the way a launch reads it and writes the files (the web mounts
// the repos read-only). They reach a session only inside the busyyaks skill of a launch — the page says what a launch
// does with them, per type from the launcher's own composition (added · replaced, and by which layer). 409 = a file
// changed on disk since it was read: Load newest offered.
import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { ApiError, apiGet, apiPost, useResource } from "../api";
import { anchor, openSet, PAGE, purpose, SOURCE_LABEL, toggleOpen, typeTitle } from "../lib/agentRules";
import {
  agentPath,
  bytes,
  changedPaths,
  changes,
  checkoutLine,
  deletedInGit,
  fieldRefusal,
  fileName,
  formOf,
  gitTag,
  globalFile,
  globalSkills,
  kindOf,
  launchLine,
  limit,
  modeOf,
  newRefRefusal,
  newSkillRefusal,
  newSkillText,
  nextForm,
  projectSkills,
  rulesPath,
  saveRefusal,
  saveStatus,
  stale,
  typeLayers,
  typeSkills,
  withMode,
  type Draft,
  type Form,
  type ProjectRulesData,
  type SaveError,
} from "../lib/projectRules";
import { Html } from "./Html";
import { RuleCard } from "./RuleCard";
import { ErrorState, Loading } from "./States";

// a type's launch, as the launcher composes it: each global file added to or replaced, then this file
function Layers({ data, typeKey, title }: { data: ProjectRulesData; typeKey: string; title: string }) {
  const layers = typeLayers(data, typeKey);
  const skills = typeSkills(data, typeKey);
  if (data.global_error) return <p className="rc-bad">global layers unknown · {data.global_error}</p>;
  if (typeof layers === "string") return <p className="rc-bad">{layers}</p>;
  const others = layers.filter((l) => l.source !== "project");
  const replaced = others.filter((l) => l.state === "replaced").length;
  return (
    <details className="rc-inherits">
      <summary>
        every {title} session starts with {others.length - replaced} global{" "}
        {others.length - replaced === 1 ? "file" : "files"}
        {replaced > 0 && ` · ${replaced} replaced`}
      </summary>
      <ol>
        {others.map((l) => {
          const g = globalFile(data, l.path);
          return (
            <li key={l.path} className={l.state === "replaced" ? "rc-replaced" : undefined}>
              <details>
                <summary>
                  <span className="mono">{l.path}</span> · {SOURCE_LABEL[l.source]} ·{" "}
                  {l.state === "replaced" ? <b>replaced by {SOURCE_LABEL[l.by ?? "project"]}</b> : "added to"}
                  {g && ` · ${g.bytes.toLocaleString("en-US")} B`}
                  {" · "}
                  <Link to={`${PAGE}#${anchor(l.path)}`}>edit globally</Link>
                </summary>
                {g?.html && <Html html={g.html} />}
              </details>
            </li>
          );
        })}
        <li>
          <b>this project&apos;s file</b> · {layers.some((l) => l.source === "project") ? "staged" : "none yet"}
        </li>
      </ol>
      {skills.length > 0 && (
        <p className="rc-ondemand">
          on demand:{" "}
          {skills.map((s, i) => (
            <span key={`${s.source}-${s.dir}`} className={s.replaced_by ? "rc-replaced" : undefined}>
              {i > 0 && " · "}
              {s.name} ({SOURCE_LABEL[s.source]}
              {s.replaced_by ? `, replaced by ${SOURCE_LABEL[s.replaced_by]}` : ""})
            </span>
          ))}
        </p>
      )}
    </details>
  );
}

// onUnsaved: the number of editors that differ from their file — the page refuses to leave the tab while it is not 0
export function ProjectRules({ slug, onUnsaved }: { slug: string; onUnsaved: (n: number) => void }) {
  const key = rulesPath(slug);
  const { data, error, loading, reload } = useResource<ProjectRulesData>(key);
  // what the form edits: the files it was loaded from + the draft. One state, so a newer read replaces both at once
  const [form, setForm] = useState<Form | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<SaveError | null>(null);
  const [saved, setSaved] = useState<string[] | null>(null);
  const [open, setOpen] = useState<string[]>(() => openSet());
  const [skillName, setSkillName] = useState("");
  const [refName, setRefName] = useState<Record<string, string>>({});

  // the first read becomes the form; a newer one only while nothing is edited (never over the operator's typing)
  useEffect(() => {
    if (!data) return;
    setForm((f) => nextForm(f, data));
  }, [data]);
  const take = (d: ProjectRulesData) => setForm(formOf(d));
  const unsaved = form ? changedPaths(form.draft, form.loaded).length : 0;
  // told to the page (it guards the tab switch), and to the browser (a reload / close asks first); 0 again on unmount
  useEffect(() => {
    onUnsaved(unsaved);
    if (unsaved === 0) return;
    const ask = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", ask);
    return () => {
      window.removeEventListener("beforeunload", ask);
      onUnsaved(0);
    };
  }, [unsaved, onUnsaved]);

  if (loading) return <Loading what="project settings" />;
  if (error && !data) return <ErrorState error={error} what="project settings" retry={reload} />;
  if (!data || !form) return null;
  const { loaded, draft } = form;

  const changed = changedPaths(draft, loaded);
  // the launch budgets are the launcher's newest answer (data), the files are the ones the form was loaded from
  const view = { ...loaded, launches: data.launches };
  const refusal = saveRefusal(draft, view);
  const status = saveStatus(saveError, saved, refusal);
  const launch = launchLine(data.launches);
  const moved = stale(form, data);
  const own = checkoutLine(data);
  const gone = deletedInGit(loaded);
  const failure = (err: unknown): SaveError =>
    err instanceof ApiError ? { status: err.status, text: err.message } : { status: 0, text: String(err) };
  const edit = (next: Draft) => {
    setForm({ loaded, draft: next });
    setSaveError(null);
    setSaved(null);
  };
  const openCard = (path: string) =>
    setOpen((o) => (o.includes(`pr-${anchor(path)}`) ? o : toggleOpen(`pr-${anchor(path)}`, o)));
  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (refusal || saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      const names = [...changed];
      take(await apiPost<ProjectRulesData>(key, { files: changes(draft, loaded) }));
      setSaved(names);
      await reload();
    } catch (err) {
      setSaveError(failure(err));
      // a conflict: read the files again so the page names what moved (nextForm keeps the edits)
      if (err instanceof ApiError && err.status === 409) void reload();
    } finally {
      setSaving(false);
    }
  };
  const loadNewest = async () => {
    try {
      take(await apiGet<ProjectRulesData>(key));
      setSaveError(null);
      await reload();
    } catch (err) {
      setSaveError(failure(err));
    }
  };

  // one file's card: its editor, and (for a file that is there or typed) Remove / Undo
  const card = (path: string, what: string, who: string, extra?: ReactNode) => {
    const id = `pr-${anchor(path)}`;
    const value = draft[path];
    const removed = value === null;
    const k = kindOf(path);
    const mode = k.kind === "agent" && value !== null ? modeOf(value ?? "") : null;
    const max =
      k.kind === "agent" ? limit(view, k.type ?? "", mode) : { bytes: loaded.max_bytes, launch: false as const };
    const isChanged = changed.includes(path);
    const exists = !!loaded.files[path];
    return (
      <RuleCard
        key={path}
        id={id}
        path={fileName(loaded, path)}
        what={removed ? `${what} · removed on Save` : what}
        who={who}
        source={SOURCE_LABEL.project}
        where={`committed in this repo: ${fileName(loaded, path)} — read at every launch`}
        size={{
          n: bytes(value ?? ""),
          max: max.bytes,
          tip: max.launch
            ? `the ${k.type} launch budget (${mode === "replace" ? "replacing" : "adding"}): skills.max_start_bytes less what the launch holds before this file · one file ≤ ${loaded.max_bytes.toLocaleString("en-US")} B`
            : `one file ≤ ${loaded.max_bytes.toLocaleString("en-US")} B${k.kind === "agent" ? ` · launch budget unknown (${data.launches.reason ?? "no answer"})` : " · the whole skill too"}`,
        }}
        git={gitTag(loaded.git[path], isChanged)}
        value={value ?? ""}
        html={null}
        changed={isChanged}
        refusal={fieldRefusal(path, value ?? null, draft, view)}
        error={loaded.errors[path] ?? null}
        readOnly={saving || removed}
        open={open.includes(id)}
        onToggle={() => setOpen((o) => toggleOpen(id, o))}
        onChange={(v) => edit({ ...draft, [path]: v })}
      >
        {extra}
        {(exists || (value !== null && value !== "")) && (
          <p className="pr-file-actions">
            {removed ? (
              <button
                type="button"
                className="btn small"
                onClick={() => edit({ ...draft, [path]: loaded.files[path]?.body ?? "" })}
              >
                Undo remove
              </button>
            ) : (
              <button
                type="button"
                className="btn small"
                disabled={saving}
                onClick={() => {
                  const next = { ...draft };
                  if (exists) next[path] = null;
                  else if (k.kind === "agent") next[path] = "";
                  else delete next[path];
                  edit(next);
                }}
              >
                {exists ? "Remove file" : "Drop new file"}
              </button>
            )}
          </p>
        )}
      </RuleCard>
    );
  };

  const globals = globalSkills(loaded);
  const mine = projectSkills(draft);
  const skillWhy = skillName ? newSkillRefusal(skillName, draft) : null;
  const addSkill = (name: string) => {
    const path = `${name}/SKILL.md`;
    edit({ ...draft, [path]: newSkillText(name, loaded) });
    openCard(path);
    setSkillName("");
  };

  return (
    <form className="pr" onSubmit={(e) => void save(e)} noValidate>
      <div className="pr-bar">
        <h2>Agent rules</h2>
        <code className="pr-dir mono" title={loaded.path}>
          {loaded.dir}/
        </code>
        <span className={`pr-scope mono ${launch.tone}`} role="status">
          {launch.text}
        </span>
      </div>
      <p className="pr-global">
        Every agent markdown of this project. An agents file adds to the global rules of its type, or replaces them
        (mode); a skill named like a global one replaces it for this project —{" "}
        <Link to={PAGE}>Settings → Agent rules</Link>.
      </p>
      {moved.length > 0 && (
        <div className="flash warn" role="status">
          <i className="dot" />
          <span>changed on disk · {moved.map((p) => fileName(data, p)).join(" · ")}</span>
        </div>
      )}
      {own && (
        <div className="flash warn" role="status">
          <i className="dot" />
          <span>{own}</span>
        </div>
      )}
      {data.git_error && (
        <div className="flash bad" role="status">
          <i className="dot" />
          <span>git state unknown · {data.git_error}</span>
        </div>
      )}
      {gone.length > 0 && (
        <div className="flash warn" role="status">
          <i className="dot" />
          <span>removed, not committed · {gone.map((p) => fileName(loaded, p)).join(" · ")}</span>
        </div>
      )}
      {Object.entries(loaded.errors)
        .filter(([p]) => !(p in draft))
        .map(([p, why]) => (
          <div className="flash bad" role="status" key={p || "dir"}>
            <i className="dot" />
            <span>not editable here · {why}</span>
          </div>
        ))}

      <h3 className="pr-group">Per agent type</h3>
      {loaded.types.map((t) => {
        const path = agentPath(t.key);
        const title = typeTitle(t);
        const value = draft[path];
        const mode = value === null || value === undefined ? "add" : modeOf(value);
        return card(
          path,
          `${title} rules · this project · ${mode === "replace" ? "replaces the global rules" : "adds to the global rules"}`,
          `every ${title} session of this project · ${purpose(t, loaded.types)}`,
          <>
            <p className="pr-mode">
              <label>
                this file{" "}
                <select
                  value={mode ?? "add"}
                  disabled={saving || value === null || mode === null}
                  onChange={(e) =>
                    edit({ ...draft, [path]: withMode(value ?? "", e.target.value as "add" | "replace") })
                  }
                >
                  <option value="add">adds to the global {title} rules</option>
                  <option value="replace">replaces the global {title} rules</option>
                </select>
              </label>
            </p>
            <Layers data={data} typeKey={t.key} title={title} />
          </>,
        );
      })}

      <h3 className="pr-group">On-demand skills</h3>
      {mine.length === 0 && <p className="muted">none in this project</p>}
      {mine.map((name) => {
        const over = globals.find((g) => g.name === name);
        const files = Object.keys(draft)
          .filter((p) => p.startsWith(`${name}/`))
          .sort((a, b) => (a.endsWith("/SKILL.md") ? -1 : b.endsWith("/SKILL.md") ? 1 : a.localeCompare(b)));
        const ref = refName[name] ?? "";
        const refWhy = ref ? newRefRefusal(name, ref, draft) : null;
        return (
          <section key={name} className="pr-skill" aria-label={`skill ${name}`}>
            <p className="pr-skill-head">
              <b className="mono">{name}</b>{" "}
              {over ? `replaces ${SOURCE_LABEL[over.source]}'s ${name} for this project` : "this project's own skill"}
            </p>
            {files.map((p) =>
              card(
                p,
                p.endsWith("/SKILL.md") ? `on-demand skill · ${name}` : `on-demand skill ${name} · reference file`,
                "on demand · every busyyaks session of this project may load it",
              ),
            )}
            <p className="pr-new">
              <input
                value={ref}
                placeholder="new reference file, e.g. checklist.md"
                aria-label={`new reference file of ${name}`}
                onChange={(e) => setRefName({ ...refName, [name]: e.target.value })}
              />
              <button
                type="button"
                className="btn small"
                disabled={!ref || !!refWhy || saving}
                onClick={() => {
                  const path = `${name}/${ref}`;
                  edit({ ...draft, [path]: `# ${ref.replace(/\.md$/, "")}\n\n` });
                  openCard(path);
                  setRefName({ ...refName, [name]: "" });
                }}
              >
                Add file
              </button>
              {refWhy && <span className="rc-bad">{refWhy}</span>}
            </p>
          </section>
        );
      })}
      <div className="pr-new">
        <input
          value={skillName}
          placeholder="new skill name"
          aria-label="new skill name"
          spellCheck={false}
          onChange={(e) => setSkillName(e.target.value.trim())}
        />
        <button
          type="button"
          className="btn small"
          disabled={!skillName || !!skillWhy || saving}
          onClick={() => addSkill(skillName)}
        >
          New skill
        </button>
        {skillWhy && <span className="rc-bad">{skillWhy}</span>}
        {globals
          .filter((g) => !mine.includes(g.name))
          .map((g) => (
            <button
              key={g.name}
              type="button"
              className="btn small"
              disabled={saving}
              title={`a copy of ${SOURCE_LABEL[g.source]}'s ${g.name} as this project's: it replaces it for this project's launches`}
              onClick={() => addSkill(g.name)}
            >
              Override {g.name}
            </button>
          ))}
      </div>

      <div className="pr-actions">
        <button className="btn primary" disabled={!!refusal || saving} aria-describedby="pr-why">
          {saving ? "Saving…" : changed.length ? `Save ${changed.length}` : "Save"}
        </button>
        <button
          type="button"
          className="btn"
          disabled={changed.length === 0 || saving}
          onClick={() => {
            take(loaded);
            setSaveError(null);
            setSaved(null);
          }}
        >
          Discard
        </button>
        <span id="pr-why" className={`pr-status ${status.tone}`} role="status">
          {status.text}
        </span>
        {status.reload && (
          <button type="button" className="btn small" onClick={() => void loadNewest()}>
            Load newest (drops edits)
          </button>
        )}
      </div>
    </form>
  );
}
