// A project's live tmux sessions: one aligned grid under the Launch bar — state dot · session name (click
// to copy `tmux attach`) · agent type + launcher when the engine registered it (blank for a hand-started session, never
// guessed) · age · Claude ↗ / iTerm ⧉ / Terminal ↗ · Stop. Header: count + Stop all.
import type { LaunchesData, TmuxSession } from "../types";
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
            return (
              <div key={s.name} className="sessions-row" role="listitem">
                <span className={`dot ${s.attached ? "ok" : ""}`} title={s.attached ? "attached" : "detached"} />
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
