// Projects: sticky toolbar (search with the `/` shortcut, counted chips, match count, expand all), the folder
// tree, the New project form, clone jobs, and the boards summary.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { apiPost, invalidate, useResource } from "../api";
import { useFlash } from "../components/Flash";
import { ProjectsTable, useTree } from "../components/ProjectsTable";
import { Select } from "../components/Select";
import { ErrorState, Loading } from "../components/States";
import { now, projectPath } from "../lib/format";
import { CHIPS, chipCounts, repos, type ChipKey, type Filter } from "../lib/tree";
import { useTitle } from "../lib/title";
import type { BoardsData, CreateResult, ProjectsData } from "../types";

export function Projects() {
  useTitle("projects");
  const { data, error, loading, reload } = useResource<ProjectsData>("/api/projects");
  const [text, setText] = useState("");
  const [chips, setChips] = useState<Set<ChipKey>>(() => new Set());
  const filter = useMemo<Filter>(() => ({ text, chips }), [text, chips]);
  const tree = useTree(data?.tree, filter);
  const search = useRef<HTMLInputElement>(null);
  const bar = useRef<HTMLElement>(null);

  useLayoutEffect(() => {
    const el = bar.current;
    if (!el) return;
    const measure = () => document.documentElement.style.setProperty("--bar-h", `${el.offsetHeight}px`);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => {
      ro.disconnect();
      document.documentElement.style.setProperty("--bar-h", "0px");
    };
  }, [data]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const a = document.activeElement as HTMLElement | null;
      const typing = a && (/input|textarea|select/i.test(a.tagName) || a.isContentEditable);
      if (e.key === "/" && search.current && a !== search.current && !typing && !document.querySelector(".menu")) {
        e.preventDefault();
        search.current.focus();
      }
      if (e.key === "Escape" && a === search.current && text) setText("");
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [text]);

  if (loading) return <Loading what="projects" />;
  if (error && !data) return <ErrorState error={error} what="projects" retry={reload} />;
  if (!data) return null;
  const counts = chipCounts(repos(data.tree), now() - 7 * 86400);
  const toggleChip = (k: ChipKey) =>
    setChips((prev) => {
      const n = new Set(prev);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });

  return (
    <>
      {error && <ErrorState error={error} what="refresh" retry={reload} />}
      {data.launcher_error && (
        <div className="flash bad">
          <i className="dot bad" />
          <span>Launcher down: {data.launcher_error}</span>
        </div>
      )}
      <h1>Projects · {data.total}</h1>
      <section className="toolbar card" ref={bar}>
        <label className="search">
          <input
            ref={search}
            type="search"
            placeholder="Filter repos"
            aria-label="Filter repos"
            autoComplete="off"
            spellCheck={false}
            value={text}
            onChange={(e) => setText(e.target.value)}
          />
          <kbd aria-hidden="true">/</kbd>
        </label>
        <div className="chips" role="group" aria-label="Quick filters">
          {CHIPS.map((c) => (
            <button
              key={c.key}
              type="button"
              className="chip"
              aria-pressed={chips.has(c.key)}
              onClick={() => toggleChip(c.key)}
            >
              {c.label} <b>{counts[c.key]}</b>
            </button>
          ))}
        </div>
        <span className="spacer" />
        <span className="muted count" aria-live="polite">
          {tree.shown} / {tree.total}
        </span>
        {tree.hasFolders && (
          <button type="button" className="btn small" onClick={() => tree.setAll(tree.anyClosed)}>
            {tree.anyClosed ? "Expand all" : "Collapse all"}
          </button>
        )}
      </section>
      <ProjectsTable
        rows={tree.rows}
        expanded={tree.expanded}
        active={tree.active}
        shown={tree.shown}
        onToggle={tree.toggle}
        launches={data.launches}
        launcherError={data.launcher_error}
      />

      <h2>New project</h2>
      <CreateForm data={data} />
      {data.jobs.length > 0 && (
        <div className="scroll">
          <table className="data jobs">
            <thead>
              <tr>
                <th>clone · {data.jobs.length}</th>
                <th>into</th>
                <th>status</th>
                <th>log</th>
              </tr>
            </thead>
            <tbody>
              {[...data.jobs].reverse().map((j, i) => (
                <tr key={`${j.path}-${i}`}>
                  <td className="mono url" title={j.url}>
                    {j.url}
                  </td>
                  <td className="mono">{j.path.replace(/^\/projects\//, "")}</td>
                  <td className="status nowrap">
                    <span className={`dot ${j.status === "done" ? "ok" : j.status === "failed" ? "bad" : ""}`} />{" "}
                    {j.status}
                    {j.exit != null && ` · exit ${j.exit}`}
                  </td>
                  <td className="mono muted log" title={j.tail ?? ""}>
                    {j.tail}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Boards />
    </>
  );
}

function CreateForm({ data }: { data: ProjectsData }) {
  const navigate = useNavigate();
  const { setFlash } = useFlash();
  const [root, setRoot] = useState(data.roots[0]?.path ?? "");
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const rootLabel = (prefix: string) => (prefix === "" ? "./" : prefix);
  // never rejects: a failed create is reported in the flash (catch below)
  const submit = async (e: FormEvent): Promise<void> => {
    e.preventDefault();
    setBusy(true);
    try {
      const r = await apiPost<CreateResult>("/api/create", { root, name, url });
      invalidate("/api/projects");
      invalidate("/api/today");
      if (r.cloning) {
        setFlash({ ok: true, text: `cloning into ${r.path} — see the clone list below` });
      } else {
        const target = r.slug ? projectPath(r.slug) : "/projects";
        void navigate(target); // BrowserRouter: navigate returns nothing to await
        setFlash({ ok: true, text: `created ${r.path} (git init)`, path: target });
      }
      setName("");
      setUrl("");
    } catch (err) {
      setFlash({ ok: false, text: `create failed: ${err instanceof Error ? err.message : String(err)}` });
    } finally {
      setBusy(false);
    }
  };
  return (
    <form className="create card" onSubmit={(e) => void submit(e)}>
      <div className="field">
        <span className="lbl" id="root-lbl">
          Folder
        </span>
        <div className="sel">
          <Select
            options={data.roots.map((r) => ({ value: r.path, label: rootLabel(r.prefix) }))}
            value={root}
            onChange={setRoot}
            ariaLabelledBy="root-lbl"
          />
        </div>
      </div>
      <label className="field">
        <span className="lbl">Name</span>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="new-repo"
          pattern="[A-Za-z0-9][A-Za-z0-9._-]{0,99}"
          autoComplete="off"
          spellCheck={false}
        />
      </label>
      <label className="field grow">
        <span className="lbl">
          Clone URL <span className="muted">· empty = new folder + git init</span>
        </span>
        <input
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="https://github.com/org/repo.git · git@github.com:org/repo.git"
          autoComplete="off"
          spellCheck={false}
        />
      </label>
      <button
        className="btn primary"
        disabled={!!data.launcher_error || busy}
        title={data.launcher_error ? "launcher down" : undefined}
      >
        {busy ? "Creating…" : "Create"}
      </button>
    </form>
  );
}

function Boards() {
  const { data, error, loading, reload } = useResource<BoardsData>("/api/boards");
  return (
    <>
      <h2>
        Boards{data ? ` · ${data.boards.length}` : ""}
        {data && (
          <span
            className={`ak-root kb-waiting${data.waiting === 0 ? " zero" : ""}`}
            style={data.theme}
            title={`cards in ${data.waiting_columns.map((k) => data.columns.find((c) => c.key === k)?.label ?? k).join(" + ")} on every board`}
          >
            <b>{data.waiting}</b> waiting for you
          </span>
        )}
      </h2>
      {loading && <Loading what="boards" inline />}
      {error && !data && <ErrorState error={error} what="boards" retry={reload} />}
      {data && data.boards.length === 0 && <p className="muted">0 boards · add a card from a project's Board tab</p>}
      {data && data.boards.length > 0 && (
        <div className="scroll ak-root" style={data.theme}>
          <table className="data kb-boards">
            <thead>
              <tr>
                <th>repo</th>
                {data.columns.map((c) => (
                  <th className="n" key={c.key}>
                    <span className={`kb-pill kb-c-${c.key}`}>
                      <i />
                      {c.label}
                    </span>
                  </th>
                ))}
                <th className="n">waiting</th>
                <th className="n">total</th>
              </tr>
            </thead>
            <tbody>
              {data.boards.map((b) => (
                <tr key={b.project}>
                  <td>
                    <Link to={`${projectPath(b.project)}?tab=board`} title={b.columns.map((c) => c.label).join(" → ")}>
                      {b.project}
                    </Link>
                    {b.columns.some((c) => !data.columns.find((t) => t.key === c.key)) && (
                      <span
                        className="tag"
                        title={`columns not on the template: ${b.columns
                          .filter((c) => !data.columns.find((t) => t.key === c.key))
                          .map((c) => c.label)
                          .join(", ")}`}
                      >
                        {" "}
                        own columns
                      </span>
                    )}
                    {b.backlog_md && (
                      <>
                        {" "}
                        <span className="tag bmd">Backlog.md</span>
                      </>
                    )}
                  </td>
                  {data.columns.map((c) => (
                    <td
                      key={c.key}
                      className={`n${(b.counts[c.key] ?? 0) === 0 ? " zero" : ""}`}
                      title={b.counts[c.key] == null ? `${b.project} has no ${c.label} column` : undefined}
                    >
                      {b.counts[c.key] ?? "—"}
                    </td>
                  ))}
                  <td className={`n${b.waiting === 0 ? " zero" : " kb-wait-n"}`}>{b.waiting}</td>
                  <td className="n">
                    <b>{b.total}</b>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
