// Agents panel: a project shows only its ACTIVE sessions until the operator unfolds it. Active = not idle /
// unknown, or running subagents, or opened by the operator (an open row never folds away under the cursor). A row is
// visible when the filter keeps it and it is active or its project is unfolded; a project with no row the filter keeps
// is not shown at all, one with only idle rows shows its header and the unfold button.
import type { AgentGroup, AgentSession } from "../types";

export type Filter = "all" | "you" | "busy" | "team";
const WAITS = new Set(["blocked", "review"]);

export const shows = (s: AgentSession, f: Filter) =>
  f === "all" ||
  (f === "you" && (WAITS.has(s.state) || s.unread)) ||
  (f === "busy" && s.state === "working") ||
  (f === "team" && s.subagents > 0);

export const active = (s: AgentSession, open: ReadonlySet<string>) =>
  (s.state !== "idle" && s.state !== "unknown") || s.unread || s.subagents > 0 || open.has(s.key);

export type FoldedRow = { s: AgentSession; visible: boolean };
export type FoldedGroup = {
  rows: FoldedRow[];
  shown: boolean;
  activeCount: number;
  idleCount: number;
  unfolded: boolean;
};

export function fold(g: AgentGroup, f: Filter, open: ReadonlySet<string>, unfolded: boolean): FoldedGroup {
  const kept = g.sessions.filter((s) => shows(s, f));
  const idleCount = kept.filter((s) => !active(s, open)).length;
  return {
    rows: g.sessions.map((s) => ({ s, visible: shows(s, f) && (unfolded || active(s, open)) })),
    shown: kept.length > 0,
    activeCount: kept.length - idleCount,
    idleCount,
    unfolded,
  };
}

// the unfolded projects, remembered by key (slug, or "other" for sessions outside any project)
export const groupKey = (g: AgentGroup) => g.slug ?? "other";
