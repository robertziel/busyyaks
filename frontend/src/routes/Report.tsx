import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useResource } from "../api";
import { Html } from "../components/Html";
import { Author, Counters } from "../components/ReportDigest";
import { ErrorState, Loading } from "../components/States";
import { ago, at, longDate } from "../lib/format";
import { useTitle } from "../lib/title";
import type { ReportData, ReportRow, TocEntry } from "../types";

// the heading currently at the top of the viewport (contents rail highlight)
function useActiveHeading(toc: TocEntry[]): string | null {
  const [active, setActive] = useState<string | null>(null);
  useEffect(() => {
    const els = toc.map((t) => document.getElementById(t.id)).filter((e): e is HTMLElement => e != null);
    if (els.length === 0) return;
    const onScroll = () => {
      let cur: string | null = null;
      for (const e of els) if (e.getBoundingClientRect().top < 120) cur = e.id;
      setActive(cur ?? els[0]?.id ?? null);
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, [toc]);
  return active;
}

function Pager({ row, dir }: { row: ReportRow | null; dir: "older" | "newer" }) {
  if (!row)
    return (
      <span className={`pager-cell ${dir} card empty`} aria-disabled="true">
        <small>{dir === "older" ? "← oldest report" : "newest report →"}</small>
      </span>
    );
  return (
    <Link className={`pager-cell ${dir} card`} to={`/reports/${row.id}`}>
      <small>{dir === "older" ? `← ${row.date}` : `${row.date} →`}</small>
      <b>{row.title}</b>
    </Link>
  );
}

export function Report() {
  const id = useParams().id ?? "";
  const { data, error, loading, reload } = useResource<ReportData>(`/api/reports/${encodeURIComponent(id)}`);
  useTitle(data?.report.title ?? `report ${id}`);
  const active = useActiveHeading(data?.report.toc ?? []);
  if (loading) return <Loading what={`report ${id}`} />;
  if (error && !data) return <ErrorState error={error} what={`report ${id}`} retry={reload} />;
  if (!data) return null;
  const r = data.report;
  const hasToc = r.toc.length >= 3;
  return (
    <>
      <nav className="report-bar" aria-label="Reports">
        <Link className="crumb" to="/reports">
          Reports
        </Link>
        <span className="muted">/</span>
        <span className="crumb-here">{r.date}</span>
        <span className="spacer" />
        {data.older ? (
          <Link
            className="btn small icon"
            to={`/reports/${data.older.id}`}
            title={`${data.older.title} · ${data.older.date}`}
            aria-label="Older report"
          >
            ←
          </Link>
        ) : (
          <span className="btn small icon" aria-disabled="true">
            ←
          </span>
        )}
        {data.newer ? (
          <Link
            className="btn small icon"
            to={`/reports/${data.newer.id}`}
            title={`${data.newer.title} · ${data.newer.date}`}
            aria-label="Newer report"
          >
            →
          </Link>
        ) : (
          <span className="btn small icon" aria-disabled="true">
            →
          </span>
        )}
      </nav>
      <div className={`report-layout${hasToc ? " has-toc" : ""}`}>
        <article className="report card">
          <header className="report-hero">
            <p className="eyebrow">{longDate(r.date)}</p>
            <h1>{r.title}</h1>
            <p className="report-meta">
              <Author author={r.author} />
              <span className="muted" title={at(r.created_at)}>
                posted {ago(r.created_at)} ago
              </span>
              <Counters digest={r.digest} />
            </p>
          </header>
          <Html html={r.html} />
        </article>
        {hasToc && (
          <aside className="toc card" aria-label="Contents">
            <p className="muted">Contents</p>
            <ol>
              {r.toc.map((t) => (
                <li key={t.id} className={`l${t.level}${active === t.id ? " active" : ""}`}>
                  <a href={`#${t.id}`}>{t.text}</a>
                </li>
              ))}
            </ol>
          </aside>
        )}
      </div>
      <nav className="report-pager" aria-label="Older and newer reports">
        <Pager row={data.older} dir="older" />
        <Pager row={data.newer} dir="newer" />
      </nav>
    </>
  );
}
