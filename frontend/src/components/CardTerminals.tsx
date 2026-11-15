// The card dialog's Terminals section (the engine's <Board cardTerminals> slot): one tab per agent session
// working on the card — its owner session, then the registrations acting as its assignee (GET /api/cards/:id/terminals).
// Nothing connects until you press Open: opening a terminal is logged on the session's cards.
import { useState } from "react";
import { useResource } from "../api";
import type { CardFull } from "../vendor/agents_kanban";
import { LiveTerminal } from "./LiveTerminal";

export type CardSession = {
  session: string;
  socket: string;
  type: string | null;
  agent: string | null;
  owner: boolean;
  project: string | null;
  live: boolean | null; // null = the launcher is down: unknown, never "not running"
};
type Sessions = { sessions: CardSession[]; sessions_error: string | null };

// the slot's renderer: a card with neither an owner session nor an assignee has no agent at work → no section
export function cardTerminals(card: CardFull) {
  if (!card.owner_session && !card.assignee) return null;
  return <CardTerminals id={card.id} />;
}

const keyOf = (s: CardSession) => `${s.socket}/${s.session}`;

export function CardTerminals({ id }: { id: number }) {
  const { data, error, loading } = useResource<Sessions>(`/api/cards/${id}/terminals`, { every: 15_000 });
  const [tab, setTab] = useState<string | null>(null);
  const [opened, setOpened] = useState<Set<string>>(new Set());

  if (loading) return <p className="muted">reading the card's sessions…</p>;
  if (error && !data) return <p className="lt-note">sessions unreadable: {error.message}</p>;
  if (!data) return null;
  const rows = data.sessions;
  if (rows.length === 0) return <p className="muted">no registered agent session works on this card</p>;
  const current = rows.find((r) => keyOf(r) === tab) ?? rows[0]!;
  const k = keyOf(current);

  return (
    <div className="lt-tabs">
      {data.sessions_error && <p className="lt-note">live state unknown: {data.sessions_error}</p>}
      <div className="lt-tablist" role="tablist" aria-label="Agent sessions">
        {rows.map((r) => (
          <button
            key={keyOf(r)}
            type="button"
            role="tab"
            className="chip"
            aria-selected={keyOf(r) === k}
            onClick={() => setTab(keyOf(r))}
            title={`${r.owner ? "owner session" : "assignee's session"}${r.type ? ` · ${r.type}` : ""}`}
          >
            <i className={`dot ${r.live === true ? "ok" : r.live === false ? "bad" : ""}`} /> {r.session}
            {r.owner && <span className="muted"> · owner</span>}
          </button>
        ))}
      </div>
      {opened.has(k) ? (
        <LiveTerminal
          key={k}
          session={current.session}
          socket={current.socket}
          onClose={() =>
            setOpened((o) => {
              const n = new Set(o);
              n.delete(k);
              return n;
            })
          }
        />
      ) : (
        <p className="lt-open">
          {current.live === false ? (
            <span className="muted">{current.session} is not running</span>
          ) : (
            <button type="button" className="btn small" onClick={() => setOpened((o) => new Set(o).add(k))}>
              Open terminal
            </button>
          )}
        </p>
      )}
    </div>
  );
}
