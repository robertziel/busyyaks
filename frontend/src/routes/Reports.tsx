import { Link } from "react-router-dom";
import { useResource } from "../api";
import { Author, Counters, Figures, Headline } from "../components/ReportDigest";
import { ErrorState, Loading } from "../components/States";
import { hm, longDate } from "../lib/format";
import { useTitle } from "../lib/title";
import type { ReportRow, ReportsData } from "../types";

export function Reports() {
  useTitle("reports");
  const { data, error, loading, reload } = useResource<ReportsData>("/api/reports");
  if (loading) return <Loading what="reports" />;
  if (error && !data) return <ErrorState error={error} what="reports" retry={reload} />;
  if (!data) return null;
  const days: { date: string; rows: ReportRow[] }[] = [];
  for (const r of data.reports) {
    const last = days[days.length - 1];
    if (last && last.date === r.date) last.rows.push(r);
    else days.push({ date: r.date, rows: [r] });
  }
  return (
    <>
      <h1>
        Reports · {data.reports.length}{" "}
        <Link className="btn small" to="/reports/components">
          Components
        </Link>
      </h1>
      {data.reports.length === 0 && <p className="muted">0 reports · post one with the MCP tool post_report</p>}
      {days.map((d) => (
        <section className="timeline" key={d.date}>
          <h4>
            <span className="commit-dot" />
            {longDate(d.date)} <span className="muted">· {d.rows.length}</span>
          </h4>
          {d.rows.map((r) => (
            <Link
              className={`card report-row${/FAILED$/.test(r.title) ? " failed" : ""}`}
              to={`/reports/${r.id}`}
              key={r.id}
            >
              <div className="rr-head">
                <b className="rr-title">{r.title}</b>
                <span className="rr-meta">
                  <Author author={r.author} />
                  <time className="muted">{hm(r.created_at)}</time>
                </span>
              </div>
              <Figures digest={r.digest} max={5} />
              <Headline digest={r.digest} />
              {r.digest.figures.length === 0 && !r.digest.headline && r.excerpt && (
                <p className="rr-excerpt muted">{r.excerpt}</p>
              )}
              <Counters digest={r.digest} />
            </Link>
          ))}
        </section>
      ))}
    </>
  );
}
