// One repo: stats, launch bar with live tmux sessions, contribution graph, commits, notes — and the Board tab.
import { ProjectIcon } from "../components/ProjectIcon";
import { useCallback, useRef, useState, type FormEvent } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { apiPost, revalidate, useResource } from "../api";
import { ProjectBoard } from "../components/Board";
import { Commits } from "../components/Commits";
import { useFlash } from "../components/Flash";
import { ContribCard } from "../components/Heatmap";
import { Html } from "../components/Html";
import { Launch } from "../components/Launch";
import { ProjectRules } from "../components/ProjectRules";
import { leaveRefusal } from "../lib/projectRules";
import { Sessions } from "../components/Sessions";
import { useStopSessions } from "../components/StopSessions";
import { ErrorState, Loading } from "../components/States";
import { ago, at, headTitle, num } from "../lib/format";
import { useTitle } from "../lib/title";
import type { Note, ProjectData, ProjectSessionsData } from "../types";

// the session list's poll: the Agents read's cadence (Agents.tsx), so the two lanes' reads age alike (card 614)
export const SESSIONS_EVERY = 10_000;

export function Project() {
  const slug = useParams()["*"] ?? "";
  const [params, setParams] = useSearchParams();
  // the board is the project's default view; settings = its rules per agent type (ProjectRules)
  const tabParam = params.get("tab");
  const tab = tabParam === "overview" || tabParam === "settings" ? tabParam : "board";
  useTitle(slug);
  const key = `/api/projects/${slug.split("/").map(encodeURIComponent).join("/")}`;
  const { data, error, loading, reload } = useResource<ProjectData>(key);
  // the sessions section + its launch bar + the launcher banner read the polled list only — never the page's one-off
  // read: a session the lead spawned, another tab started or that ended shows without a reload (card 614)
  const live = useResource<ProjectSessionsData>(`${key}/sessions`, { every: SESSIONS_EVERY });
  const reloadLive = live.reload;
  const { busy: stopping, stop } = useStopSessions(slug, () => void reloadLive());
  // the Settings tab's unsaved edits (ProjectRules reports them): leaving the tab would drop them without a word
  const unsaved = useRef(0);
  const onUnsaved = useCallback((n: number) => {
    unsaved.current = n;
  }, []);
  const { setFlash } = useFlash();
  if (loading) return <Loading what={`project ${slug}`} />;
  if (error && !data) return <ErrorState error={error} what={slug} retry={reload} />;
  if (!data) return null;
  const p = data.project;
  const ls = live.data;
  const setTab = (t: "overview" | "board" | "settings") => {
    const refusal = leaveRefusal(tab, t, unsaved.current);
    if (refusal) {
      setFlash({ ok: false, text: refusal });
      return;
    }
    const n = new URLSearchParams(params);
    if (t === "board") n.delete("tab");
    else {
      n.set("tab", t);
      n.delete("card");
      n.delete("archived");
    }
    setParams(n);
  };
  return (
    <>
      {error && <ErrorState error={error} what="refresh" retry={reload} />}
      {ls?.launcher_error && (
        <div className="flash bad">
          <i className="dot bad" />
          <span>Launcher down: {ls.launcher_error}</span>
        </div>
      )}
      {live.error && !ls && (
        <div className="flash bad">
          <i className="dot bad" />
          <span>Sessions unknown: {live.error.message}</span>
        </div>
      )}
      <h1 className="proj-title">
        <ProjectIcon slug={p.slug} icon={p.icon} size={30} />
        <span className="proj-name">{p.slug}</span>
        <span className={`tag ${p.own ? "own" : "up"}`}>{p.own ? "own" : "upstream"}</span>
        {!p.present && <span className="tag bad">not present</span>}
      </h1>
      <div className="tabs" role="tablist" aria-label="Project views">
        <button type="button" role="tab" aria-selected={tab === "board"} onClick={() => setTab("board")}>
          Board
        </button>
        <button type="button" role="tab" aria-selected={tab === "overview"} onClick={() => setTab("overview")}>
          Overview
        </button>
        <button type="button" role="tab" aria-selected={tab === "settings"} onClick={() => setTab("settings")}>
          Settings
        </button>
      </div>
      {ls && ls.launches.types.length > 0 && (
        <section className="launchbar card">
          <Sessions
            sessions={[...ls.sessions].sort((a, b) => b.created - a.created)}
            launches={ls.launches}
            busy={stopping}
            stop={(names, what) => void stop(names, what)}
            launch={<Launch slug={p.slug} launches={ls.launches} launcherError={ls.launcher_error} compact />}
            reloadSessions={reloadLive}
            sessionsError={live.error?.message ?? null}
          />
        </section>
      )}
      {tab === "board" ? (
        <ProjectBoard slug={p.slug} />
      ) : tab === "settings" ? (
        <ProjectRules slug={p.slug} onUnsaved={onUnsaved} />
      ) : (
        <>
          <section className="stats">
            <div>
              <b className="mono" title={headTitle(p)}>
                {p.head_label ?? "—"}
              </b>
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
