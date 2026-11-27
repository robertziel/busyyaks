import { Link } from "react-router-dom";
import { useResource } from "../api";
import { ContribCard } from "../components/Heatmap";
import { GraphTile, StatRow, Tiles } from "../components/GraphTile";
import { DailyTable, dayTiles, MergedPrs, PrStatusLine } from "../components/DailyStats";
import { ProjectsTable, useTree } from "../components/ProjectsTable";
import { ReportCard } from "../components/ReportCard";
import { ErrorState, Loading, RefreshError } from "../components/States";
import { CommitLog, Head, PendingLine, WeekBars, YearFactList } from "../components/TodayParts";
import { ago } from "../lib/format";
import { useTitle } from "../lib/title";
import { attention, commitsLabel, localDay, reportBlock, weekLabel, yearFacts } from "../lib/today";
import { useMedia } from "../lib/useMedia";
import { useNow } from "../lib/useNow";
import { refreshed, useLiveRev } from "../lib/live";
import { useMemo, useState } from "react";
import type { Scan, TodayData } from "../types";

// the page stays live — GET /api/today/rev every 4s (≈100 B: a digest of what the page shows + the last
// finished scan); /api/today is re-read only when the digest changes. Before, it was fetched once, so the tiles kept
// the load's numbers while the scan label suggested they were fresh.
const REV_EVERY_MS = 4000;
type TodayRev = { rev: string; scan: Scan | null };

// The order is: today's figures and what wants attention (pending work, scan / live / launcher errors),
// what changed today (commits beside merged PRs), the day's report beside the per-day table, then history (the year,
// 7 days per repo) and the active projects with their launch bars. A phone folds the lists shorter; nothing the page knows is left out.
export function Today() {
  useTitle("today");
  const { data, error, loading, reload } = useResource<TodayData>("/api/today");
  const [liveScan, setLiveScan] = useState<Scan | null | undefined>(undefined);
  const live = useLiveRev<TodayRev>("/api/today/rev", refreshed(reload), {
    every: REV_EVERY_MS,
    onRev: (b) => setLiveScan(b.scan),
  });
  const now = useNow(1000); // the "scan Ns ago" label counts up between polls instead of freezing at the load
  const narrow = useMedia("(max-width: 800px)");
  const [showProjects, setShowProjects] = useState(true);
  const tree = useTree(data?.active_tree);
  const year = data?.year;
  const day = localDay(new Date(now)); // the live tick: past midnight the streak and active days count the new day
  const facts = useMemo(() => (year ? yearFacts(year, new Date(`${day}T00:00`)) : null), [year, day]);
  if (loading) return <Loading what="today's activity" />;
  if (error && !data) return <ErrorState error={error} what="today" retry={reload} />;
  if (!data || !facts) return null;
  const s = data.stats;
  const scan = liveScan !== undefined ? liveScan : data.scan;
  const tiles = dayTiles(data.days, data.today, s);
  const pending = attention(data.active_tree, s);
  const report = reportBlock(data.today, data.reports, data.latest);
  return (
    <div className="today">
      {error && <RefreshError error={error} retry={reload} />}
      <section className="card statband">
        <Tiles>
          {tiles.map((t) => (
            <GraphTile key={t.label} {...t} />
          ))}
        </Tiles>
        <StatRow
          stats={[
            { label: "tracked", value: s.repos },
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
        <PendingLine label="uncommitted" unit="files" list={pending.dirty} fold={narrow ? 4 : 8} />
        <PendingLine label="unpushed" unit="commits" list={pending.unpushed} fold={narrow ? 4 : 8} />
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

      <div className="td-grid td-now">
        <section>
          <Head title="Today" parts={commitsLabel(s, data.days, data.today, data.today_commits.length)} />
          <CommitLog commits={data.today_commits} fold={narrow ? 6 : 14} />
        </section>
        <section>
          <Head title="Merged PRs" parts={[`${data.github_off ? "—" : data.merged_prs_total} in ${data.days.length}d`]}>
            <PrStatusLine status={data.pr_status} off={data.github_off} />
          </Head>
          <div className="td-panel">
            <MergedPrs
              prs={data.merged_prs}
              total={data.merged_prs_total}
              fold={narrow ? 6 : 14}
              off={data.github_off}
            />
          </div>
        </section>
      </div>

      <div className="td-grid td-day">
        <section>
          <Head title="Report" parts={report.parts}>
            <Link to="/reports">all →</Link>
          </Head>
          {report.shown.map((r) => (
            <ReportCard key={r.id} report={r} collapsible />
          ))}
        </section>
        <section>
          <Head title="Daily" parts={[`${data.days.length}d`]} />
          <DailyTable days={data.days} today={data.today} />
        </section>
      </div>

      <section>
        <ContribCard
          counts={data.year}
          caption="mine · 365d"
          facts={<YearFactList facts={facts} all={data.year_all} repos={data.projects_total} />}
        />
      </section>

      <section>
        <Head title="7 days" parts={[weekLabel(data.week_activity, s.active7)]} />
        <WeekBars rows={data.week_activity} />
      </section>

      <section>
        <Head title="Projects" parts={["active 7d", String(tree.total)]}>
          <Link to="/projects">all {data.projects_total} →</Link>
          <button
            type="button"
            className="td-toggle"
            aria-expanded={showProjects}
            aria-controls="td-projects"
            onClick={() => setShowProjects(!showProjects)}
          >
            {showProjects ? "Hide" : "Show"}
          </button>
        </Head>
        <div id="td-projects" hidden={!showProjects}>
          <ProjectsTable
            rows={tree.rows}
            expanded={tree.expanded}
            active={false}
            shown={tree.shown}
            onToggle={tree.toggle}
            launches={data.launches}
            launcherError={data.launcher_error}
          />
        </div>
      </section>
    </div>
  );
}
