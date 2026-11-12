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

// label = the column's name, shown before the number on a phone (the table's header is hidden there); an unknown
// value (null) is its own class: the phone layout hides zeros, never an unknown (shown —, never 0)
function Num({ v, warn, label, col }: { v: number | null; warn?: boolean; label: string; col?: string }) {
  const c = col ? ` ${col}` : "";
  if (v == null)
    return (
      <td role="cell" className={`n unknown${c}`} data-label={label} title="unknown">
        —
      </td>
    );
  const cls = v === 0 ? " zero" : warn ? " warn" : "";
  return (
    <td role="cell" className={`n${cls}${c}`} data-label={label}>
      {warn && v > 0 ? <span className="pip">{v}</span> : v}
    </td>
  );
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
      {/* explicit roles: the phone layout turns rows into flex cards, which drops the table's semantics in browsers */}
      <table className="data tree" role="table">
        <thead role="rowgroup">
          <tr role="row">
            <th role="columnheader" className="name">
              repo
            </th>
            <th role="columnheader" className="branch">
              branch
            </th>
            <th role="columnheader" className="n when">
              last commit
            </th>
            <th role="columnheader" className="n" title={`commits in the last ${window} days`}>
              {window}d
            </th>
            <th role="columnheader" className="n mine">
              mine
            </th>
            <th role="columnheader" className="n">
              dirty
            </th>
            <th role="columnheader" className="n">
              unpushed
            </th>
            {hasLaunch && (
              <>
                <th role="columnheader" className="n tmux">
                  tmux
                </th>
                <th role="columnheader" className="launch">
                  launch
                </th>
              </>
            )}
          </tr>
        </thead>
        <tbody role="rowgroup">
          {rows.map((r) => {
            if (r.kind === "folder") {
              const n = r.node;
              const lc = n.last_commit_at;
              const isOpen = expanded.has(n.path);
              return (
                <tr
                  role="row"
                  key={`f:${n.path}`}
                  className="folder"
                  style={{ "--depth": r.depth } as CSSProperties}
                  onClick={folderClick(n.path)}
                >
                  <td role="cell" className="name">
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
                  <td role="cell" className="branch" />
                  <td role="cell" className={`n when${lc && lc < month ? " old" : ""}`} title={at(lc)}>
                    {ago(lc, t)}
                  </td>
                  <Num v={n.commits_window} label={`${window}d`} />
                  <Num v={n.mine_window} label="mine" col="mine" />
                  <Num v={n.dirty} warn label="dirty" />
                  <Num v={n.unpushed} warn label="unpushed" />
                  {hasLaunch && (
                    <>
                      <td role="cell" className="n tmux" data-label={n.live > 0 ? "tmux" : undefined}>
                        {n.live > 0 && <span className="badge live">{n.live}</span>}
                      </td>
                      <td role="cell" className="launch" />
                    </>
                  )}
                </tr>
              );
            }
            const p = r.project;
            const lc = p.last_commit_at;
            return (
              <tr role="row" key={p.slug} className="repo" style={{ "--depth": r.depth } as CSSProperties}>
                <td role="cell" className="name">
                  {r.depth > 0 && <span className={`branchline${r.last ? " last" : ""}`} aria-hidden="true" />}
                  <Link to={projectPath(p.slug)} className="pname" title={p.slug}>
                    <ProjectIcon slug={p.slug} icon={p.icon} size={16} />
                    <span className="pname-t">{r.name}</span>
                  </Link>
                  {!p.own && (
                    <span className="tag up" title="upstream: a repo you do not own">
                      upstream
                    </span>
                  )}
                </td>
                <td role="cell" className="branch">
                  <span className="mono" title={p.branch ?? "—"}>
                    {p.branch ?? "—"}
                  </span>
                </td>
                <td role="cell" className={`n when${lc && lc < month ? " old" : ""}`} title={at(lc)}>
                  {ago(lc, t)}
                </td>
                <Num v={p.commits_window} label={`${window}d`} />
                <Num v={p.mine_window} label="mine" col="mine" />
                <Num v={p.dirty} warn label="dirty" />
                <Num v={p.unpushed} warn label="unpushed" />
                {hasLaunch && (
                  <>
                    <td
                      role="cell"
                      className="n tmux"
                      data-label="tmux"
                      title={p.sessions.map((s) => s.name).join(", ")}
                    >
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
                    <td role="cell" className="launch">
                      <Launch slug={p.slug} launches={launches} launcherError={launcherError} />
                    </td>
                  </>
                )}
              </tr>
            );
          })}
          {shown === 0 && (
            <tr role="row" className="empty">
              <td role="cell" colSpan={hasLaunch ? 9 : 7} className="muted">
                0 repos match
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
