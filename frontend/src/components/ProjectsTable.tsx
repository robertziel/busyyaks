// Projects as a folder tree table: folders carry totals and expand/collapse (remembered); repos link to their page.
// Filtering (text + chips) comes from the page; the hook keeps the open state and computes the visible rows.
import { ProjectIcon } from "./ProjectIcon";
import { useCallback, useMemo, useState, type CSSProperties, type MouseEvent } from "react";
import { Link } from "react-router-dom";
import { ago, at, now, projectPath } from "../lib/format";
import * as store from "../lib/store";
import { filtering, visible, type Filter, type Row } from "../lib/tree";
import type { LaunchesData, TreeNode } from "../types";
import { Launch } from "./Launch";

const NO_FILTER: Filter = { text: "", chips: new Set() };

export function useTree(tree: TreeNode[] | undefined, filter: Filter = NO_FILTER) {
  const [open, setOpenState] = useState<Record<string, boolean>>(() => store.getJSON("busyyaks.open", {}));
  const setOpen = useCallback((next: Record<string, boolean>) => {
    setOpenState(next);
    store.set("busyyaks.open", JSON.stringify(next));
  }, []);
  const week = now() - 7 * 86400;
  const v = useMemo(() => visible(tree ?? [], filter, open, week), [tree, filter, open, week]);
  const folders = useMemo(() => v.rows.filter((r) => r.kind === "folder"), [v.rows]);
  const allFolders = useMemo(() => {
    const out: string[] = [];
    const walk = (nodes: TreeNode[]) =>
      nodes.forEach((n) => {
        if (n.type === "folder") {
          out.push(n.path);
          walk(n.children);
        }
      });
    walk(tree ?? []);
    return out;
  }, [tree]);
  const anyClosed = allFolders.some((p) => !open[p]);
  return {
    ...v,
    folders,
    hasFolders: allFolders.length > 0,
    anyClosed,
    toggle: (path: string) => setOpen({ ...open, [path]: !open[path] }),
    setAll: (expanded: boolean) => setOpen(Object.fromEntries(allFolders.map((p) => [p, expanded]))),
    active: filtering(filter),
  };
}

function Num({ v, warn }: { v: number | null; warn?: boolean }) {
  if (v == null) return <td className="n zero">—</td>;
  const cls = v === 0 ? " zero" : warn ? " warn" : "";
  return <td className={`n${cls}`}>{warn && v > 0 ? <span className="pip">{v}</span> : v}</td>;
}

type Props = {
  rows: Row[];
  expanded: Set<string>;
  active: boolean;
  shown: number;
  onToggle: (path: string) => void;
  launches: LaunchesData;
  launcherError: string | null;
  window?: number;
};

export function ProjectsTable({ rows, expanded, active, shown, onToggle, launches, launcherError, window = 7 }: Props) {
  const t = now();
  const month = t - 30 * 86400;
  const hasLaunch = launches.types.length > 0;
  const folderClick = (path: string) => (e: MouseEvent<HTMLTableRowElement>) => {
    if (active || (e.target as HTMLElement).closest("a, .launch, button:not(.twisty)")) return;
    onToggle(path);
  };
  return (
    <div className="scroll tree-wrap">
      <table className="data tree">
        <thead>
          <tr>
            <th className="name">repo</th>
            <th className="kind">kind</th>
            <th className="branch">branch</th>
            <th className="n when">last commit</th>
            <th className="n">commits {window}d</th>
            <th className="n">mine</th>
            <th className="n">dirty</th>
            <th className="n">unpushed</th>
            {hasLaunch && (
              <>
                <th className="n tmux">tmux</th>
                <th className="launch">launch</th>
              </>
            )}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            if (r.kind === "folder") {
              const n = r.node;
              const lc = n.last_commit_at;
              const isOpen = expanded.has(n.path);
              return (
                <tr
                  key={`f:${n.path}`}
                  className="folder"
                  style={{ "--depth": r.depth } as CSSProperties}
                  onClick={folderClick(n.path)}
                >
                  <td className="name">
                    <button
                      type="button"
                      className="twisty"
                      aria-expanded={isOpen}
                      aria-label={`${isOpen ? "Collapse" : "Expand"} ${n.path}`}
                      onClick={() => !active && onToggle(n.path)}
                    />
                    <span className="ficon" />
                    <b>{n.name}/</b> <span className="muted">{n.repos}</span>
                  </td>
                  <td className="kind" />
                  <td className="branch" />
                  <td className={`n when${lc && lc < month ? " old" : ""}`} title={at(lc)}>
                    {ago(lc, t)}
                  </td>
                  <Num v={n.commits_window} />
                  <Num v={n.mine_window} />
                  <Num v={n.dirty} warn />
                  <Num v={n.unpushed} warn />
                  {hasLaunch && (
                    <>
                      <td className="n tmux">{n.live > 0 && <span className="badge live">{n.live}</span>}</td>
                      <td className="launch" />
                    </>
                  )}
                </tr>
              );
            }
            const p = r.project;
            const lc = p.last_commit_at;
            return (
              <tr key={p.slug} className="repo" style={{ "--depth": r.depth } as CSSProperties}>
                <td className="name">
                  {r.depth > 0 && <span className={`branchline${r.last ? " last" : ""}`} aria-hidden="true" />}
                  <Link to={projectPath(p.slug)} className="pname">
                    <ProjectIcon slug={p.slug} icon={p.icon} size={16} />
                    {r.name}
                  </Link>
                </td>
                <td className="kind">
                  <span className={`tag ${p.own ? "own" : "up"}`}>{p.own ? "own" : "upstream"}</span>
                </td>
                <td className="branch">
                  <span className="mono" title={p.branch ?? "—"}>
                    {p.branch ?? "—"}
                  </span>
                </td>
                <td className={`n when${lc && lc < month ? " old" : ""}`} title={at(lc)}>
                  {ago(lc, t)}
                </td>
                <Num v={p.commits_window} />
                <Num v={p.mine_window} />
                <Num v={p.dirty} warn />
                <Num v={p.unpushed} warn />
                {hasLaunch && (
                  <>
                    <td className="n tmux" title={p.sessions.map((s) => s.name).join(", ")}>
                      {p.sessions.length > 0 && (
                        <a
                          className="badge live termbadge"
                          href={[...p.sessions].sort((a, b) => b.created - a.created)[0]!.terminal_url}
                          target="_blank"
                          rel="noopener"
                          title={`Open the newest team terminal · ${p.sessions.map((s) => s.name).join(", ")}`}
                        >
                          {p.sessions.length} ↗
                        </a>
                      )}
                    </td>
                    <td className="launch">
                      <Launch slug={p.slug} launches={launches} launcherError={launcherError} />
                    </td>
                  </>
                )}
              </tr>
            );
          })}
          {shown === 0 && (
            <tr className="empty">
              <td colSpan={hasLaunch ? 10 : 8} className="muted">
                0 repos match
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
