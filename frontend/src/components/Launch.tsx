// The Launch bar: the vendored engine's LaunchBar (one split pill per agent type from config/kanban.yml — Launch ·
// Sub team · Plain — with the type's launchers in its menu, and "running / cap") over busyyaks's routes. The types
// and the cap state come with the page (/api/projects, /api/today, /api/projects/:slug: `launches`), so a table of
// thirty repos makes no extra request; per-project counts are read off the engine's session list. A launch posts
// /api/launch {slug, type, launcher}; the engine registers the session (a lead adopts the board's ownerless cards),
// bin/launcher starts it, and its Remote Control verdict lands in the flash — never presented as fine when it failed
// (a claude that never came up is a 422 instead: the error shown verbatim; a 201 failed = up but waiting on a dialog).
import { useMemo } from "react";
import { apiPost, invalidate } from "../api";
import type { LauncherStart, LaunchesData, LaunchResult } from "../types";
import { LaunchBar, type LaunchApi } from "../vendor/agents_kanban";
import { useFlash } from "./Flash";

export function launchFlash(r: LaunchResult) {
  const s = r.result as LauncherStart;
  // a hermes launcher (kind hermes) has no remote control: its start check is its process in the pane
  const up = s.process !== undefined ? s.process === "on" : s.remote_control === "on";
  const ok = up && s.trust !== "failed" && s.trust !== "left";
  const rc =
    s.process === "on"
      ? `${s.process_name} running · no remote control`
      : s.process !== undefined
        ? `START CHECK FAILED: ${s.reason ?? "no reason given"}`
        : s.remote_control === "on"
          ? `remote control ${s.remote_control_name}`
          : `REMOTE CONTROL FAILED: ${s.reason ?? "no reason given"}`;
  const trust =
    s.trust === "accepted"
      ? " · folder trusted"
      : s.trust === "failed"
        ? ` · TRUST PROMPT NOT ANSWERED: ${s.trust_reason ?? ""}`
        : s.trust === "left"
          ? ` · TRUST PROMPT LEFT FOR YOU: ${s.trust_reason ?? ""}`
          : "";
  const owns = r.adopted.length ? ` · owns ${r.adopted.map((c) => `#${c.id}`).join(", ")}` : "";
  return {
    ok,
    text: `${r.type}/${r.launcher} → tmux ${r.session} as ${r.agent}${owns} · ${rc}${trust}`,
    attach: `tmux attach -t ${r.session}`,
  };
}

// The page's launches, narrowed to one board: running_here = the engine's registered sessions of that type on that
// project; follows = the newest running session of the type it `launcher_follows` on that project (the engine's
// Store#followed_launcher over the same running list — the engine still judges the launch and refuses another launcher).
export function launchesFor(all: LaunchesData, slug: string): LaunchesData {
  const sessions = all.concurrency?.sessions ?? [];
  return {
    ...all,
    types: all.types.map((t) => {
      const lead = t.launcher_follows
        ? sessions.filter((s) => s.type === t.launcher_follows && s.project === slug).at(-1)
        : undefined;
      return {
        ...t,
        running_here: all.concurrency ? sessions.filter((s) => s.type === t.key && s.project === slug).length : null,
        follows: lead ? { type: lead.type, session: lead.session, launcher: lead.launcher } : null,
      };
    }),
  };
}

export function busyyaksLaunchApi(all: LaunchesData): LaunchApi {
  return {
    launches: (slug) => Promise.resolve(launchesFor(all, slug)),
    launch: (slug, body) => apiPost<LaunchResult>("/api/launch", { slug, ...body }),
  };
}

type Props = { slug: string; launches: LaunchesData; launcherError: string | null };

export function Launch({ slug, launches, launcherError }: Props) {
  const { setFlash } = useFlash();
  // the launcher down: the engine's data says so (sessions_error) and every pill is greyed with that reason
  const data = useMemo<LaunchesData>(
    () =>
      launcherError && !launches.sessions_error
        ? { ...launches, concurrency: null, sessions_error: launcherError }
        : launches,
    [launches, launcherError],
  );
  const api = useMemo(() => busyyaksLaunchApi(data), [data]);
  return (
    <LaunchBar
      api={api}
      slug={slug}
      refreshEvery={0}
      className="launchpair"
      onLaunched={(r) => {
        setFlash(launchFlash(r));
        invalidate("/api/projects");
        invalidate("/api/today");
      }}
    />
  );
}
