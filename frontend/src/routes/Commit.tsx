// /commit/:sha — on GitHub when the origin is there (the server already redirects direct hits; client-side
// navigations land here and go on to GitHub), else the commit's own detail.
import { useEffect } from "react";
import { Link, useParams } from "react-router-dom";
import { useResource } from "../api";
import { Avatar } from "../components/Commits";
import { ErrorState, Loading } from "../components/States";
import { at, projectPath } from "../lib/format";
import { useTitle } from "../lib/title";
import type { CommitData } from "../types";

export function Commit() {
  const sha = useParams().sha ?? "";
  const { data, error, loading, reload } = useResource<CommitData>(`/api/commits/${encodeURIComponent(sha)}`);
  useTitle(sha.slice(0, 7));
  useEffect(() => {
    if (data?.commit.url) window.location.assign(data.commit.url);
  }, [data]);
  if (loading) return <Loading what={`commit ${sha}`} />;
  if (error && !data) return <ErrorState error={error} what={`commit ${sha}`} retry={reload} />;
  if (!data) return null;
  const c = data.commit;
  if (c.url)
    return (
      <p className="muted">
        opening <a href={c.url}>{c.url}</a>…
      </p>
    );
  return (
    <>
      <h1 className="mono">{c.sha.slice(0, 12)}</h1>
      <article className="card">
        <p className="c-subject">{c.subject}</p>
        <p className="c-meta">
          <Avatar name={c.author} email={c.email} /> <b>{c.author}</b> committed {at(c.committed_at)} ·{" "}
          <Link to={projectPath(c.project_slug)}>{c.project_slug}</Link>
        </p>
        <p className="mono muted">
          {c.sha} · {data.project?.remote ?? "no remote"} — not on github.com, so no web link
        </p>
      </article>
    </>
  );
}
