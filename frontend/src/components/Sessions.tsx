// A project's live tmux sessions as three status lanes, worst first:
//   Needs you — an answer card per session stopped on the operator: the dialog on its screen (its keys pressed in the
//               session, only while that dialog is still there), its card question (a choice is posted as the operator's
//               answer), or its handed-over card (the PR to review);
//   Working   — a chip per working session: its face, the phase its screen shows (thinking · tool + its name · writing ·
//               subagents; nothing shown = "working", never guessed), the card it is on (linked) and the turn's time;
//   Quiet     — a pill per finished / idle / unknown session (past QUIET_LIMIT folded behind "+N quiet"), and the
//               compact launch bar.
// The chip (its main button) is the primary action: a click or Enter opens the built-in live terminal. Keyboard
// focus shows its detail strip (full name · type · launcher · age, tool, time · tokens) — a hover never does; on touch
// the first tap only shows the strip, whose "Open terminal" button opens it. `⋯` holds the rest: Open in Claude app · Copy iTerm
// attach · Open external terminal · Copy tmux attach · Stop session; the section's `⋯` holds Stop all.
// Live state is the Agents sidebar's read (/api/agents, shared, refreshed every 10 s by the sidebar); the session list is
// the project page's own poll (/api/projects/:slug/sessions, card 614). Either read listing a name the other does not
// asks that other again at once (behindKey): a session started or ended anywhere enters / leaves the lanes on the next
// read of either, not on a reload.
import { useEffect, useReducer, useRef, useState, type ReactNode } from "react";
import { invalidate, useResource } from "../api";
import {
  behindKey,
  buildLanes,
  catchUpTracker,
  CHIP_START,
  chipReducer,
  inTerminal,
  liveIssue,
  refocusAfterTerminal,
} from "../lib/sessionLanes";
import type { AgentsData, LaunchesData, TmuxSession } from "../types";
import { LiveTerminal } from "./LiveTerminal";
import { SessionLanesView } from "./SessionLanes";

type Props = {
  sessions: TmuxSession[];
  launches: LaunchesData;
  busy: string | null;
  stop: (names: string[], what: string) => void;
  launch: ReactNode; // the compact launch bar, shown in the Quiet lane
  reloadSessions: () => unknown; // read the session list again now
  sessionsError: string | null; // the session list's last refresh failed: the lanes show its last read
};

// Ask a read again when the other one names something it does not — once per new difference (the first render only
// records: both reads are fresh then)
function useCatchUp(key: string | null, ask: () => unknown) {
  const [step] = useState(catchUpTracker);
  useEffect(() => {
    if (step(key)) ask();
  }, [step, key, ask]);
}

const askAgents = () => invalidate("/api/agents");

export function Sessions({ sessions, launches, busy, stop, launch, reloadSessions, sessionsError }: Props) {
  const { data: agents, error } = useResource<AgentsData>("/api/agents");
  const agentNames = agents ? agents.groups.flatMap((g) => g.sessions.map((s) => s.name)) : null;
  const tmuxNames = sessions.map((s) => s.name);
  useCatchUp(agentNames && behindKey(agentNames, tmuxNames), reloadSessions); // a new session the list has not seen yet
  useCatchUp(agentNames && behindKey(tmuxNames, agentNames), askAgents); // a listed session the Agents read lacks
  const lanes = buildLanes(
    sessions,
    agents ? agents.groups.flatMap((g) => g.sessions) : null,
    launches.concurrency
      ? launches.concurrency.sessions
      : { unknown: launches.sessions_error ?? "the launcher's session list was not answered" },
  );
  const [chip, dispatch] = useReducer(chipReducer, CHIP_START);
  const [quietOpen, setQuietOpen] = useState(false);
  const open = chip.open
    ? [...lanes.you, ...lanes.working, ...lanes.quiet].find((l) => l.tmux.name === chip.open)
    : null;
  // the session ended while its terminal was open (the terminal unmounts with it): close it; focus moves to the lanes
  // only when it was inside that terminal (now gone with it) — someone typing elsewhere keeps their focus
  const termFocus = useRef(false);
  useEffect(() => {
    const track = (e: FocusEvent) => (termFocus.current = inTerminal(e.target));
    document.addEventListener("focusin", track);
    return () => document.removeEventListener("focusin", track);
  }, []);
  const gone = chip.open !== null && !open?.agent;
  useEffect(() => {
    if (!gone) return;
    dispatch({ type: "closeTerminal" });
    if (refocusAfterTerminal(termFocus.current, document.activeElement, document.body))
      document.querySelector<HTMLElement>(".lanes")?.focus();
  }, [gone]);
  return (
    <>
      <SessionLanesView
        lanes={lanes}
        chip={chip}
        dispatch={dispatch}
        quietOpen={quietOpen}
        onQuietOpen={setQuietOpen}
        busy={busy}
        stop={stop}
        launch={launch}
        issue={liveIssue(agents, error?.message ?? null, sessionsError)}
      />
      {open?.agent && (
        <LiveTerminal
          key={open.tmux.name}
          session={open.tmux.name}
          socket={open.agent.socket}
          overlay
          onClose={() => {
            const name = open.tmux.name;
            dispatch({ type: "closeTerminal" });
            // focus back on the chip that opened it (not <body>)
            // the session gone by then (stopped, ended): the lanes themselves, never <body>
            window.requestAnimationFrame(() =>
              (
                document.querySelector<HTMLElement>(`[data-chip="${CSS.escape(name)}"]`) ??
                document.querySelector<HTMLElement>(".lanes")
              )?.focus(),
            );
          }}
        />
      )}
    </>
  );
}
