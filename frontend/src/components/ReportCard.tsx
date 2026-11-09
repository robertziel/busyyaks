// A report card (home): date, title, author, digest counters + the server-rendered body; collapsible ones fade out past 460px until opened.
import { useLayoutEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { ago, at, longDate } from "../lib/format";
import type { Report } from "../types";
import { Html } from "./Html";
import { Author, Counters } from "./ReportDigest";

export function ReportCard({ report, collapsible }: { report: Report; collapsible: boolean }) {
  const md = useRef<HTMLDivElement>(null);
  const [overflowing, setOverflowing] = useState(false);
  const [open, setOpen] = useState(false);
  useLayoutEffect(() => {
    const el = md.current;
    if (el && collapsible) setOverflowing(el.scrollHeight > el.clientHeight + 4);
  }, [report.html, collapsible]);
  const cls = ["card", "report-card", collapsible && "collapsible", overflowing && "overflowing", open && "open"]
    .filter(Boolean)
    .join(" ");
  return (
    <article className={cls}>
      <header className="report-head">
        <div className="report-head-main">
          <p className="eyebrow">{longDate(report.date)}</p>
          <h3>
            <Link to={`/reports/${report.id}`}>{report.title}</Link>
          </h3>
          <p className="report-meta">
            <Author author={report.author} />
            <span className="muted" title={at(report.created_at)}>
              {ago(report.created_at)} ago
            </span>
            <Counters digest={report.digest} />
          </p>
        </div>
        <Link className="btn small" to={`/reports/${report.id}`}>
          Open
        </Link>
      </header>
      <Html ref={md} html={report.html} />
      {collapsible && (
        <div className="fade">
          <button type="button" className="btn small" onClick={() => setOpen(true)}>
            Show full report
          </button>
        </div>
      )}
    </article>
  );
}
