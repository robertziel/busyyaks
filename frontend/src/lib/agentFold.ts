// Agents panel: a project shows only its ACTIVE sessions until the operator unfolds it. Active = not idle /
// unknown, or running subagents, or opened by the operator (an open row never folds away under the cursor). A row is
// visible when the filter keeps it and it is active or its project is unfolded; a project with no row the filter keeps
// is not shown at all, one with only idle rows shows its header and the unfold button.
// Hide finished: a toggle beside the filters; on, a `finished` session (every card it owns is done) is
// left out under every filter — unless the operator has its row open.
import * as store from "./store";
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

// the toggle's state, remembered per browser ("1" = on; anything else, or no storage, = off)
export const HIDE_FINISHED_KEY = "busyyaks.aghidefinished";
export const hideFinishedStored = () => store.get(HIDE_FINISHED_KEY) === "1";
export const storeHideFinished = (on: boolean) => store.set(HIDE_FINISHED_KEY, on ? "1" : "0");

export const hidden = (s: AgentSession, hideFinished: boolean, open: ReadonlySet<string>) =>
  hideFinished && s.state === "finished" && !open.has(s.key);

// what the toggle hides (or would hide): the finished sessions that are not open
export const finishedHideable = (groups: readonly AgentGroup[], open: ReadonlySet<string>) =>
  groups.reduce((n, g) => n + g.sessions.filter((s) => hidden(s, true, open)).length, 0);

export function fold(
  g: AgentGroup,
  f: Filter,
  open: ReadonlySet<string>,
  unfolded: boolean,
  hideFinished = false,
): FoldedGroup {
  const keeps = (s: AgentSession) => shows(s, f) && !hidden(s, hideFinished, open);
  const kept = g.sessions.filter(keeps);
  const idleCount = kept.filter((s) => !active(s, open)).length;
  return {
    rows: g.sessions.map((s) => ({ s, visible: keeps(s) && (unfolded || active(s, open)) })),
    shown: kept.length > 0,
    activeCount: kept.length - idleCount,
    idleCount,
    unfolded,
  };
}

// the unfolded projects, remembered by key (slug, or "other" for sessions outside any project)
export const groupKey = (g: AgentGroup) => g.slug ?? "other";
