// A project's live tmux sessions: one aligned grid under the Launch bar — state dot · session name (click
// to copy `tmux attach`) · agent type + launcher when the engine registered it (blank for a hand-started session, never
// guessed) · age · Claude ↗ / iTerm ⧉ / Terminal ↗ · Stop. Header: count + Stop all.
// Each session wears its agent's face (two eyes): coloured by the registered type, its mood the Agents sidebar's live
// state of that session (the same /api/agents read, shared) — a session nobody registered gets a still, typeless face.
import type { AgentSession, AgentsData, LaunchesData, TmuxSession } from "../types";
import { useResource } from "../api";
import { moodOf, AgentFace } from "../vendor/agents_kanban";
import { ago, at } from "../lib/format";
import { ClaudeLink, CopyChip, ItermCopy, TerminalLink } from "./Copy";
import { StopButton } from "./StopSessions";

type Props = {
  sessions: TmuxSession[];
  launches: LaunchesData;
  busy: string | null;
  stop: (names: string[], what: string) => void;
};

export function Sessions({ sessions, launches, busy, stop }: Props) {
  const reg = new Map((launches.concurrency?.sessions ?? []).map((r) => [r.session, r]));
  // the Agents sidebar's read (Layout mounts it on every page) keeps this key fresh every 10 s: no poll of its own here
  const { data: agents } = useResource<AgentsData>("/api/agents");
  const live = new Map<string, AgentSession>(
    (agents?.groups ?? []).flatMap((g) => g.sessions.map((a) => [a.name, a] as [string, AgentSession])),
  );
  return (
    <div className="sessions">
      <div className="sessions-head">
        <b>tmux</b>
        <span className="muted">{sessions.length}</span>
        <span className="spacer" />
        {sessions.length > 1 && (
          <StopButton
            label={`Stop all (${sessions.length})`}
            title="kill every tmux session of this project — to start fresh"
            busy={busy === "*"}
            disabled={busy !== null}
            onClick={() =>
              stop(
                sessions.map((s) => s.name),
                "*",
              )
            }
          />
        )}
      </div>
      {sessions.length > 0 && (
        <div className="sessions-grid" role="list">
          {sessions.map((s) => {
            const r = reg.get(s.name);
            const a = live.get(s.name);
            return (
              <div key={s.name} className="sessions-row" role="listitem">
                <span
                  className={`sessions-face${s.attached ? " attached" : ""}`}
                  title={s.attached ? "attached" : "detached"}
                >
                  <AgentFace
                    name={r?.agent ?? s.name}
                    type={r?.type ?? null}
                    mood={a ? moodOf({ state: a.state, phase: a.phase }) : null}
                    size={26}
                  />
                </span>
                <CopyChip
                  text={`tmux attach -t ${s.name}`}
                  className="sessions-name"
                  title={`tmux attach -t ${s.name} · click to copy`}
                >
                  <code>{s.name}</code>
                </CopyChip>
                <span className="sessions-type mono muted">{r ? `${r.type} · ${r.launcher}` : ""}</span>
                <span className="sessions-age mono muted" title={`started ${at(s.created)}`}>
                  {ago(s.created)}
                </span>
                <span className="sessions-links">
                  <ClaudeLink url={s.claude_url} name={s.name} />
                  <ItermCopy command={s.ssh_attach} />
                  <TerminalLink url={s.terminal_url} name={s.name} />
                </span>
                <StopButton
                  label="Stop"
                  title={`kill tmux session ${s.name}`}
                  busy={busy === s.name}
                  disabled={busy !== null}
                  onClick={() => stop([s.name], s.name)}
                />
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
