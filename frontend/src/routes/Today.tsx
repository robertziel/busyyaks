import { Link } from "react-router-dom";
import { useResource } from "../api";
import { ContribCard } from "../components/Heatmap";
import { GraphTile, StatRow, Tiles } from "../components/GraphTile";
import { Commits } from "../components/Commits";
import { DailyTable, dayTiles, MergedPrs, PrStatusLine } from "../components/DailyStats";
import { ProjectsTable, useTree } from "../components/ProjectsTable";
import { ReportCard } from "../components/ReportCard";
import { ErrorState, Loading } from "../components/States";
import { ago, projectPath } from "../lib/format";
import { useTitle } from "../lib/title";
import { useNow } from "../lib/useNow";
import { useLiveRev } from "../lib/live";
import { useState } from "react";
import type { Scan, TodayData } from "../types";

// the page stays live — GET /api/today/rev every 4s (≈100 B: a digest of what the page shows + the last
// finished scan); /api/today is re-read only when the digest changes. Before, it was fetched once, so the tiles kept
// the load's numbers while the scan label suggested they were fresh.
const REV_EVERY_MS = 4000;
type TodayRev = { rev: string; scan: Scan | null };

export function Today() {
  useTitle("today");
  const { data, error, loading, reload } = useResource<TodayData>("/api/today");
  const [liveScan, setLiveScan] = useState<Scan | null | undefined>(undefined);
  const live = useLiveRev<TodayRev>("/api/today/rev", () => void reload(), {
    every: REV_EVERY_MS,
    onRev: (b) => setLiveScan(b.scan),
  });
  useNow(1000); // the "scan Ns ago" label counts up between polls instead of freezing at the load
  const tree = useTree(data?.active_tree);
  if (loading) return <Loading what="today's activity" />;
  if (error && !data) return <ErrorState error={error} what="today" retry={reload} />;
  if (!data) return null;
  const s = data.stats;
  const scan = liveScan !== undefined ? liveScan : data.scan;
  const max = Math.max(0, ...data.week_activity.map((a) => a.commits));
  const tiles = dayTiles(data.days, data.today, s);
  return (
    <>
      {error && <ErrorState error={error} what="refresh" retry={reload} />}
      <section className="card statband">
        <Tiles>
          {tiles.map((t) => (
            <GraphTile key={t.label} {...t} />
          ))}
        </Tiles>
        <StatRow
          stats={[
            { label: "tracked", value: s.repos },
            { label: "uncommitted", value: s.dirty, tone: s.dirty > 0 ? "warn" : undefined },
            { label: "unpushed", value: s.unpushed, tone: s.unpushed > 0 ? "warn" : undefined },
            {
              label: "scan",
              value: (
                <>
                  <i className={`dot ${scan ? (scan.error ? "bad" : "ok") : ""}`} />{" "}
                  {scan?.finished_at != null ? `${ago(scan.finished_at)} ago` : "never"}
                </>
              ),
              tone: scan?.error ? "bad" : undefined,
              title: scan?.error ? `scan failed: ${scan.error}` : undefined,
            },
          ]}
        />
      </section>
      {scan?.error && <p className="err">scan failed: {scan.error}</p>}
      {live.error && (
        <p className="err">
          live updates failing: {live.error} · figures as of the last good poll{" "}
          {live.at ? `${ago(Math.floor(live.at / 1000))} ago` : "— never"}
        </p>
      )}
      {data.launcher_error && (
        <div className="flash bad">
          <i className="dot bad" />
          <span>Launcher down: {data.launcher_error}</span>
        </div>
      )}

      <ContribCard
        counts={data.year}
        caption={
          <>
            your commits in the last year · {data.year_all} across all {data.projects_total} repos
          </>
        }
      />

      <section className="grid2">
        <div>
          <h2>Daily · {data.days.length}d</h2>
          <DailyTable days={data.days} today={data.today} />
        </div>
        <div>
          <h2>
            Your merged PRs · {data.merged_prs_total} in {data.days.length}d
          </h2>
          <PrStatusLine status={data.pr_status} />
          <MergedPrs prs={data.merged_prs} total={data.merged_prs_total} />
        </div>
      </section>

      <section>
        <h2>Report · {data.today}</h2>
        {data.reports.length === 0 && (
          <>
            <p className="muted">0 reports today{data.latest && " · latest below"}</p>
            {data.latest && <ReportCard report={data.latest} collapsible />}
          </>
        )}
        {data.reports.map((r) => (
          <ReportCard key={r.id} report={r} collapsible />
        ))}
      </section>

      <section className="grid2">
        <div>
          <h2>Today · {data.today_commits.length} commits</h2>
          <Commits commits={data.today_commits} showRepo fold={10} />
        </div>
        <div>
          <h2>7 days</h2>
          {data.week_activity.length === 0 ? (
            <p className="muted">0 commits in 7 days</p>
          ) : (
            <table className="data bars">
              <tbody>
                {data.week_activity.map((a) => (
                  <tr key={a.project_slug}>
                    <td>
                      <Link to={projectPath(a.project_slug)}>{a.project_slug}</Link>
                    </td>
                    <td className="bar">
                      <span
                        style={
                          { "--w": `${max === 0 ? 0 : Math.round((a.commits * 100) / max)}%` } as React.CSSProperties
                        }
                      />
                    </td>
                    <td className="n">{a.commits}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </section>

      <section>
        <h2>Projects · active 7d · {tree.total}</h2>
        <ProjectsTable
          rows={tree.rows}
          expanded={tree.expanded}
          active={false}
          shown={tree.shown}
          onToggle={tree.toggle}
          launches={data.launches}
          launcherError={data.launcher_error}
        />
        <p>
          <Link to="/projects">all {data.projects_total} →</Link>
        </p>
      </section>
    </>
  );
}
