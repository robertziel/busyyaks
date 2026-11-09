// /github — the GitHub network: the operator's dashboard feed (github.com/feed: releases, new repos, forks, pushes per
// repo, activity by repo), repos the people the operator follows starred, accounts they started following,
// in a 24h / 7d / 30d window. Data from GET /api/github (the collector's snapshots); the repo and people lists are the
// server's tl:github markup (same as the report block). The collector's status is always on screen: a failed
// collection shows its error next to the age of the data below it — never stale data as fresh.
import { Link, useLocation } from "react-router-dom";
import { useResource } from "../api";
import { Html } from "../components/Html";
import { ErrorState, Loading } from "../components/States";
import { at, now } from "../lib/format";
import { feedLine, parseWindow, repoSummary, statusLine, WINDOWS } from "../lib/github";
import { useTitle } from "../lib/title";
import type { GithubData } from "../types";

const MARK = (
  <svg viewBox="0 0 16 16" aria-hidden="true" className="ghp-mark">
    <path
      fill="currentColor"
      d="M8 .2a8 8 0 0 0-2.5 15.6c.4 0 .5-.2.5-.4v-1.5c-2.2.5-2.7-1-2.7-1-.4-.9-.9-1.2-.9-1.2-.7-.5.1-.5.1-.5.8.1 1.2.8 1.2.8.7 1.3 1.9.9 2.3.7.1-.5.3-.9.5-1.1-1.8-.2-3.6-.9-3.6-4 0-.9.3-1.6.8-2.1-.1-.2-.4-1 .1-2.1 0 0 .7-.2 2.2.8a7.5 7.5 0 0 1 4 0c1.5-1 2.2-.8 2.2-.8.4 1.1.2 1.9.1 2.1.5.6.8 1.3.8 2.1 0 3.1-1.9 3.8-3.6 4 .3.3.6.8.6 1.5v2.2c0 .2.1.5.6.4A8 8 0 0 0 8 .2z"
    />
  </svg>
);

export function GitHub() {
  useTitle("GitHub");
  const { search } = useLocation();
  const w = parseWindow(search);
  const hours = "error" in w ? null : w.hours;
  const { data, error, loading, reload } = useResource<GithubData>(hours ? `/api/github?hours=${hours}` : null, {
    every: 300_000,
  });

  const head = (
    <div className="ghp-head">
      <h1>
        {MARK} GitHub network
        {data && (
          <a className="ghp-who" href={`https://github.com/${data.login}?tab=following`} target="_blank" rel="noopener">
            @{data.login} · <b>{data.followees.length}</b> following
          </a>
        )}
      </h1>
      <div className="tabs ghp-tabs" role="tablist" aria-label="Window">
        {WINDOWS.map((x) => (
          <Link
            key={x.key}
            role="tab"
            aria-selected={!("error" in w) && w.key === x.key}
            to={x.key === "24h" ? "/github" : `/github?window=${x.key}`}
          >
            {x.key}
          </Link>
        ))}
      </div>
    </div>
  );
  if ("error" in w)
    return (
      <>
        {head}
        <p className="flash bad">{w.error}</p>
      </>
    );
  if (loading)
    return (
      <>
        {head}
        <Loading what="GitHub network" />
      </>
    );
  if (error && !data)
    return (
      <>
        {head}
        <ErrorState error={error} what="GitHub network" retry={reload} />
      </>
    );
  if (!data) return null;

  const st = statusLine(data.status, now());
  const fl = feedLine(data.feed.status, now(), data.window.from);
  const label = "error" in w ? "" : w.key;
  const hasData = data.status.last_ok_at != null;
  return (
    <div className="ghp">
      {head}
      <p className={`ghp-status t-${st.tone}`} role={st.tone === "ok" ? undefined : "alert"}>
        <i className="tl-dot" />
        {st.parts.map((p, i) => (
          <span key={i}>{p}</span>
        ))}
      </p>
      <div className="ghp-grid">
        <div className="ghp-main">
          <section className="ghp-feed" aria-label="Feed">
            <h2 className="ghp-h">
              Feed <span className="ghp-n">{data.feed.items.length}</span>
              <span className="ghp-hint">
                github.com/feed · {data.feed.total} events · {label}
              </span>
            </h2>
            <p className={`ghp-status ghp-fstatus t-${fl.tone}`} role={fl.tone === "ok" ? undefined : "alert"}>
              <i className="tl-dot" />
              {fl.parts.map((p, i) => (
                <span key={i}>{p}</span>
              ))}
            </p>
            {data.feed.total > 0 ? (
              <Html html={data.html.feed} className="ghn-wrap" />
            ) : (
              <p className="ghn-empty">
                {data.feed.status.last_ok_at != null
                  ? `no feed events in ${label}`
                  : "no data: the feed has not been read"}
              </p>
            )}
            {data.feed.by_repo.length > 0 && (
              <details className="ghp-byrepo">
                <summary>
                  Activity by repo <span className="ghp-n">{data.feed.by_repo.length}</span>
                </summary>
                <ul>
                  {data.feed.by_repo.map((r) => {
                    const sm = repoSummary(r);
                    return (
                      <li key={r.repo}>
                        <a href={`https://github.com/${r.repo}`} target="_blank" rel="noopener">
                          {r.repo}
                        </a>
                        <span className="ghp-bt">{sm.types}</span>
                        <span className="ghp-ba">{sm.actors}</span>
                      </li>
                    );
                  })}
                </ul>
              </details>
            )}
          </section>
          <section aria-label="Starred">
            <h2 className="ghp-h">
              Starred <span className="ghp-n">{data.repos.length}</span>
              <span className="ghp-hint">repos the people you follow starred · {label}</span>
            </h2>
            {data.repos.length > 0 ? (
              <Html html={data.html.repos} className="ghn-wrap" />
            ) : (
              <p className="ghn-empty">
                {hasData ? `nothing new in ${label}` : "no data: the collector has not completed a run"}
              </p>
            )}
          </section>
        </div>
        <aside className="ghp-side">
          <section aria-label="Followed">
            <h2 className="ghp-h">
              Followed <span className="ghp-n">{data.people.length}</span>
            </h2>
            {data.status.follows_partial && data.status.follows_since != null && (
              <p className="ghp-note">follows have no date on GitHub · tracked since {at(data.status.follows_since)}</p>
            )}
            {data.people.length > 0 ? (
              <Html html={data.html.people} className="ghn-wrap" />
            ) : (
              <p className="ghn-empty">{hasData ? `nothing new in ${label}` : "no data"}</p>
            )}
          </section>
          <section className="ghp-net" aria-label="People you follow">
            <h2 className="ghp-h">
              You follow <span className="ghp-n">{data.followees.length}</span>
            </h2>
            <ul className="ghp-avatars">
              {data.followees.map((f) => (
                <li key={f.login}>
                  <a
                    href={`https://github.com/${f.login}`}
                    target="_blank"
                    rel="noopener"
                    title={f.name ? `${f.name} · @${f.login}` : `@${f.login}`}
                  >
                    {f.avatar ? (
                      <img
                        src={`${f.avatar}${f.avatar.includes("?") ? "&" : "?"}s=64`}
                        alt={f.login}
                        loading="lazy"
                        width={32}
                        height={32}
                      />
                    ) : (
                      <span className="ghn-noav">{f.login[0]?.toUpperCase()}</span>
                    )}
                  </a>
                </li>
              ))}
            </ul>
          </section>
        </aside>
      </div>
    </div>
  );
}
