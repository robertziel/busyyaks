// GitHub-style commit list: day groups on a rail, avatar, subject → GitHub, SHA chip + copy, folded after `fold`.
import { useState, type CSSProperties } from "react";
import { Link } from "react-router-dom";
import { ago, at, dayKey, dayLabel, hue, initials, projectPath } from "../lib/format";
import type { Commit } from "../types";

export function Avatar({ name, email }: { name: string; email: string }) {
  return (
    <span className="avatar" style={{ "--h": hue(email) } as CSSProperties} title={`${name} <${email}>`}>
      {initials(name)}
    </span>
  );
}

function CopySha({ sha }: { sha: string }) {
  const [done, setDone] = useState(false);
  const [title, setTitle] = useState("Copy full SHA");
  const copy = () => {
    if (!navigator.clipboard) return setTitle("Clipboard needs HTTPS");
    navigator.clipboard.writeText(sha).then(
      () => {
        setDone(true);
        window.setTimeout(() => setDone(false), 1400);
      },
      () => setTitle("Copy refused by the browser"),
    );
  };
  return (
    <button
      type="button"
      className={`copy${done ? " done" : ""}`}
      onClick={copy}
      title={title}
      aria-label="Copy full SHA"
    />
  );
}

type Props = { commits: Commit[]; showRepo: boolean; fold?: number };

export function Commits({ commits, showRepo, fold }: Props) {
  const [all, setAll] = useState(false);
  if (commits.length === 0) return <p className="muted">0 commits</p>;
  const limit = fold && !all ? fold : Infinity;
  const days: { key: string; date: Date; items: { c: Commit; index: number }[] }[] = [];
  commits.forEach((c, index) => {
    const key = dayKey(c.committed_at);
    const last = days[days.length - 1];
    if (last && last.key === key) last.items.push({ c, index });
    else days.push({ key, date: new Date(c.committed_at * 1000), items: [{ c, index }] });
  });
  return (
    <>
      {days.map((d) => {
        const visible = d.items.filter((i) => i.index < limit);
        if (visible.length === 0) return null;
        return (
          <div className="commit-day" key={d.key}>
            <h4>
              <span className="commit-dot" />
              Commits on {dayLabel(d.date)} <span className="muted">· {d.items.length}</span>
            </h4>
            <ol className="commits">
              {visible.map(({ c }) => (
                <li key={c.sha}>
                  <div className="c-main">
                    <p className="c-subject">
                      {c.url ? (
                        <a href={c.url} target="_blank" rel="noopener">
                          {c.subject}
                        </a>
                      ) : (
                        c.subject
                      )}
                    </p>
                    <p className="c-meta">
                      <Avatar name={c.author} email={c.email} /> <b>{c.author}</b> committed{" "}
                      <span title={at(c.committed_at)}>{ago(c.committed_at)} ago</span>
                      {showRepo && (
                        <>
                          {" "}
                          ·{" "}
                          <Link className="repo-chip" to={projectPath(c.project_slug)}>
                            {c.project_slug}
                          </Link>
                        </>
                      )}
                      {c.mine && <span className="tag own">mine</span>}
                    </p>
                  </div>
                  <div className="c-actions">
                    <CopySha sha={c.sha} />
                    {c.url ? (
                      <a className="sha-btn" href={c.url} target="_blank" rel="noopener">
                        {c.sha.slice(0, 7)}
                      </a>
                    ) : (
                      <span className="sha-btn">{c.sha.slice(0, 7)}</span>
                    )}
                  </div>
                </li>
              ))}
            </ol>
          </div>
        );
      })}
      {fold && !all && commits.length > fold && (
        <button type="button" className="btn small" onClick={() => setAll(true)}>
          Show {commits.length - fold} more
        </button>
      )}
    </>
  );
}
