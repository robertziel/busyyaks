// One repo: stats, launch bar with live tmux sessions, contribution graph, commits, notes — and the Board tab.
import { ProjectIcon } from "../components/ProjectIcon";
import { useState, type FormEvent } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { apiPost, revalidate, useResource } from "../api";
import { ProjectBoard } from "../components/Board";
import { Commits } from "../components/Commits";
import { useFlash } from "../components/Flash";
import { ContribCard } from "../components/Heatmap";
import { Html } from "../components/Html";
import { Launch } from "../components/Launch";
import { Sessions } from "../components/Sessions";
import { useStopSessions } from "../components/StopSessions";
import { ErrorState, Loading } from "../components/States";
import { ago, at, num } from "../lib/format";
import { useTitle } from "../lib/title";
import type { Note, ProjectData } from "../types";

export function Project() {
  const slug = useParams()["*"] ?? "";
  const [params, setParams] = useSearchParams();
  const tab = params.get("tab") === "overview" ? "overview" : "board"; // the board is the project's default view
  useTitle(slug);
  const key = `/api/projects/${slug.split("/").map(encodeURIComponent).join("/")}`;
  const { data, error, loading, reload } = useResource<ProjectData>(key);
  const { busy: stopping, stop } = useStopSessions(slug, () => void reload());
  if (loading) return <Loading what={`project ${slug}`} />;
  if (error && !data) return <ErrorState error={error} what={slug} retry={reload} />;
  if (!data) return null;
  const p = data.project;
  const live = [...p.sessions].sort((a, b) => b.created - a.created);
  const setTab = (t: "overview" | "board") => {
    const n = new URLSearchParams(params);
    if (t === "board") n.delete("tab");
    else {
      n.set("tab", "overview");
      n.delete("card");
      n.delete("archived");
    }
    setParams(n);
  };
  return (
    <>
      {error && <ErrorState error={error} what="refresh" retry={reload} />}
      {data.launcher_error && (
        <div className="flash bad">
          <i className="dot bad" />
          <span>Launcher down: {data.launcher_error}</span>
        </div>
      )}
      <h1>
        <ProjectIcon slug={p.slug} icon={p.icon} size={30} />
        {p.slug} <span className={`tag ${p.own ? "own" : "up"}`}>{p.own ? "own" : "upstream"}</span>
        {!p.present && <span className="tag bad">not present</span>}
      </h1>
      <div className="tabs" role="tablist" aria-label="Project views">
        <button type="button" role="tab" aria-selected={tab === "board"} onClick={() => setTab("board")}>
          Board
        </button>
        <button type="button" role="tab" aria-selected={tab === "overview"} onClick={() => setTab("overview")}>
          Overview
        </button>
      </div>
      {data.launches.types.length > 0 && (
        <section className="launchbar card">
          <Launch slug={p.slug} launches={data.launches} launcherError={data.launcher_error} />
          <Sessions
            sessions={live}
            launches={data.launches}
            busy={stopping}
            stop={(names, what) => void stop(names, what)}
          />
        </section>
      )}
      {tab === "board" ? (
        <ProjectBoard slug={p.slug} />
      ) : (
        <>
          <section className="stats">
            <div>
              <b className="mono">{p.branch ?? "—"}</b>
              <span>Branch</span>
            </div>
            <div>
              <b>{ago(p.last_commit_at)}</b>
              <span>Last commit</span>
            </div>
            <div>
              <b>{p.commits_window}</b>
              <span>Commits 7d</span>
            </div>
            <div>
              <b>{p.mine_window}</b>
              <span>Mine 7d</span>
            </div>
            <div>
              <b className={p.dirty > 0 ? "warn" : ""}>{p.dirty}</b>
              <span>Uncommitted</span>
            </div>
            <div>
              <b className={(p.unpushed ?? 0) > 0 ? "warn" : ""}>{num(p.unpushed)}</b>
              <span>Unpushed</span>
            </div>
          </section>
          <p className="mono muted">
            {p.repo_url ? (
              <a href={p.repo_url} target="_blank" rel="noopener">
                {p.remote}
              </a>
            ) : (
              (p.remote ?? "no remote")
            )}{" "}
            · {p.path} · scanned {ago(p.scanned_at)} ago
          </p>

          <ContribCard counts={data.year} caption="commits in the last year" />

          <section className="grid2 wide-left">
            <div>
              <h2>Commits · {data.commits.length}</h2>
              <Commits commits={data.commits} showRepo={false} fold={30} />
            </div>
            <div>
              <h2>Notes · {data.notes.length}</h2>
              <NoteForm slug={p.slug} onAdded={() => void revalidate(key)} />
              {data.notes.map((n: Note) => (
                <div className="card note" key={n.id}>
                  <div className="muted">
                    {n.author} · {at(n.created_at)}
                  </div>
                  <Html html={n.html} />
                </div>
              ))}
            </div>
          </section>
        </>
      )}
    </>
  );
}

function NoteForm({ slug, onAdded }: { slug: string; onAdded: () => void }) {
  const { setFlash } = useFlash();
  const [body, setBody] = useState("");
  const [busy, setBusy] = useState(false);
  // never rejects: a failed post is reported in the flash (catch below)
  const submit = async (e: FormEvent): Promise<void> => {
    e.preventDefault();
    if (!body.trim()) return;
    setBusy(true);
    try {
      await apiPost("/api/notes", { slug, body });
      setBody("");
      onAdded();
      setFlash({ ok: true, text: "note added" });
    } catch (err) {
      setFlash({ ok: false, text: `note failed: ${err instanceof Error ? err.message : String(err)}` });
    } finally {
      setBusy(false);
    }
  };
  return (
    <form className="note" onSubmit={(e) => void submit(e)}>
      <textarea
        rows={3}
        required
        value={body}
        onChange={(e) => setBody(e.target.value)}
        aria-label="New note (markdown)"
      />
      <button className="btn primary" disabled={busy}>
        {busy ? "Adding…" : "Add note"}
      </button>
    </form>
  );
}
