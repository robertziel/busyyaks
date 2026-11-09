// The projects folder tree as rows, and the toolbar's filtering (text + chips) — pure, so it is testable.
import type { FolderNode, Project, TreeNode } from "../types";

export type Row =
  | { kind: "folder"; node: FolderNode; depth: number; parent: string; last: boolean }
  | { kind: "repo"; project: Project; name: string; depth: number; parent: string; last: boolean };

export function flatten(nodes: TreeNode[], depth = 0, parent = ""): Row[] {
  const out: Row[] = [];
  nodes.forEach((n, i) => {
    const last = i === nodes.length - 1;
    if (n.type === "folder") {
      out.push({ kind: "folder", node: n, depth, parent, last });
      out.push(...flatten(n.children, depth + 1, n.path));
    } else {
      out.push({ kind: "repo", project: n.project, name: n.name, depth, parent, last });
    }
  });
  return out;
}

export function repos(nodes: TreeNode[]): Project[] {
  return flatten(nodes).flatMap((r) => (r.kind === "repo" ? [r.project] : []));
}

export type ChipKey = "own" | "upstream" | "active" | "dirty" | "unpushed" | "live";
export const CHIPS: { key: ChipKey; label: string }[] = [
  { key: "own", label: "Own" },
  { key: "upstream", label: "Upstream" },
  { key: "active", label: "Active 7d" },
  { key: "dirty", label: "Uncommitted" },
  { key: "unpushed", label: "Unpushed" },
  { key: "live", label: "tmux" },
];

export function chipMatch(p: Project, key: ChipKey, week: number): boolean {
  switch (key) {
    case "own":
      return p.own;
    case "upstream":
      return !p.own;
    case "active":
      return (p.last_commit_at ?? 0) >= week;
    case "dirty":
      return p.dirty > 0;
    case "unpushed":
      return (p.unpushed ?? 0) > 0;
    case "live":
      return p.sessions.length > 0;
  }
}

export function chipCounts(projects: Project[], week: number): Record<ChipKey, number> {
  const out = { own: 0, upstream: 0, active: 0, dirty: 0, unpushed: 0, live: 0 };
  for (const p of projects) for (const c of CHIPS) if (chipMatch(p, c.key, week)) out[c.key]++;
  return out;
}

export type Filter = { text: string; chips: Set<ChipKey> };
export const filtering = (f: Filter) => f.text.trim() !== "" || f.chips.size > 0;

export function matches(p: Project, f: Filter, week: number): boolean {
  const t = f.text.trim().toLowerCase();
  if (t && !p.slug.toLowerCase().includes(t)) return false;
  for (const c of f.chips) if (!chipMatch(p, c, week)) return false;
  return true;
}

function ancestors(parent: string): string[] {
  const out: string[] = [];
  while (parent) {
    out.push(parent);
    const i = parent.lastIndexOf("/");
    parent = i < 0 ? "" : parent.slice(0, i);
  }
  return out;
}

export type Visible = { rows: Row[]; shown: number; total: number; expanded: Set<string> };

// Which rows show: when filtering, matching repos and the folders on their path (all expanded);
// otherwise the open folders' children (open = user state).
export function visible(nodes: TreeNode[], f: Filter, open: Record<string, boolean>, week: number): Visible {
  const rows = flatten(nodes);
  const active = filtering(f);
  const hit = new Set<string>();
  let shown = 0;
  let total = 0;
  const repoShown = new Map<Row, boolean>();
  for (const r of rows) {
    if (r.kind !== "repo") continue;
    total++;
    const m = matches(r.project, f, week);
    repoShown.set(r, m);
    if (m) {
      shown++;
      for (const a of ancestors(r.parent)) hit.add(a);
    }
  }
  const openPath = (parent: string) => ancestors(parent).every((a) => open[a]);
  const expanded = new Set<string>();
  const out: Row[] = [];
  for (const r of rows) {
    if (r.kind === "folder") {
      const isOpen = active ? hit.has(r.node.path) : !!open[r.node.path];
      if (isOpen) expanded.add(r.node.path);
      const show = active ? hit.has(r.node.path) : openPath(r.parent);
      if (show) out.push(r);
    } else {
      const show = active ? !!repoShown.get(r) : openPath(r.parent);
      if (show) out.push(r);
    }
  }
  return { rows: out, shown, total, expanded };
}
