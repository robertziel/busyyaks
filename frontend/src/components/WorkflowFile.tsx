// The board's line about its workflow file (card #429): <repo>/.busyyaks/workflow.yml is the board's source, applied by
// the writer service. Shown only when something is wrong — the file is refused (the board runs the shape last applied)
// or the writer has not looked for 3 sync periods (an edit since is not applied). GET /api/projects/*slug/workflow-file.
import { useEffect, useState } from "react";
import { apiGet } from "../api";
import { ago } from "../lib/format";

export type WorkflowFileState = {
  file: string;
  path: string;
  applied_at: string | null;
  error: string | null;
  error_at: string | null;
  checked_at: string | null;
  stale: boolean;
};

const POLL_MS = 30_000;
const secs = (iso: string | null) => (iso ? Math.floor(Date.parse(iso) / 1000) : null);

export function workflowFileLines(s: WorkflowFileState): string[] {
  const out: string[] = [];
  if (s.error && s.error_at)
    out.push(
      `${s.file} refused ${ago(secs(s.error_at))} ago: ${s.error} · board = last applied ${ago(secs(s.applied_at))} ago`,
    );
  else if (s.error) out.push(`${s.file}: ${s.error}`);
  if (s.stale && s.checked_at) out.push(`writer down · last look ${ago(secs(s.checked_at))} ago`);
  return out;
}

export function WorkflowFile({ slug, enc }: { slug: string; enc: (slug: string) => string }) {
  const [state, setState] = useState<WorkflowFileState | null>(null);
  const [readError, setReadError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    const read = () =>
      apiGet<WorkflowFileState>(`/api/projects/${enc(slug)}/workflow-file`)
        .then((s) => {
          if (!live) return;
          setState(s);
          setReadError(null);
        })
        .catch((e: unknown) => live && setReadError(e instanceof Error ? e.message : String(e)));
    void read();
    const t = window.setInterval(() => void read(), POLL_MS);
    return () => {
      live = false;
      window.clearInterval(t);
    };
  }, [slug, enc]);
  const lines = [
    ...(state ? workflowFileLines(state) : []),
    ...(readError ? [`workflow file state unread: ${readError}`] : []),
  ];
  if (!lines.length) return null;
  return (
    <div className="flash bad workflow-file" title={state?.path}>
      <i className="dot bad" />
      <span>{lines.join(" · ")}</span>
    </div>
  );
}
