// /session-boards — every agent session's own board: a session opens one with the MCP tool
// kanban_session_board and only that session writes it; here it is read-only. Archived after the host's idle_hours
// with no activity (kept, never deleted). Data from GET /api/session-boards (the engine's Api#session_boards), drawn by
// the vendored SessionBoards.
import { Link, useLocation } from "react-router-dom";
import { useResource } from "../api";
import { ErrorState, Loading } from "../components/States";
import { useTitle } from "../lib/title";
import { SessionBoards as Boards, type SessionBoardsData } from "../vendor/agents_kanban";

export function SessionBoards() {
  useTitle("Session boards");
  const q = new URLSearchParams(useLocation().search);
  const archived = q.get("archived") === "1";
  // a session card's link (Kanban.card_path): ?session=<s>&card=<id> marks that board and card
  const cardParam = Number(q.get("card"));
  const focus = { session: q.get("session"), card: Number.isInteger(cardParam) && cardParam > 0 ? cardParam : null };
  const { data, error, loading, reload } = useResource<SessionBoardsData>(
    `/api/session-boards${archived ? "?archived=1" : ""}`,
    { every: 30_000 },
  );
  return (
    <section className="session-boards">
      <div className="sb-head">
        <h1>
          Session boards{data && <b> · {data.session_boards.length}</b>}
          {data && <span className="sb-idle"> · archived after {data.idle_hours} h idle</span>}
        </h1>
        <div className="tabs" role="tablist" aria-label="Which boards">
          <Link to="/session-boards" role="tab" aria-selected={!archived}>
            Live
          </Link>
          <Link to="/session-boards?archived=1" role="tab" aria-selected={archived}>
            + archived
          </Link>
        </div>
      </div>
      {error ? (
        <ErrorState error={error} what="session boards" retry={reload} />
      ) : loading || !data ? (
        <Loading what="session boards" />
      ) : (
        <Boards data={data} focus={focus} />
      )}
    </section>
  );
}
