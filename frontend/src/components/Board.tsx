// The project's Board tab: the vendored agents_kanban Board (frontend/src/vendor/agents_kanban) bound to this app —
// its KanbanApi port over api.ts (session cookie + X-CSRF-Token, docs/API-kanban.md routes), the open card / panel /
// archived flag in the URL (?card=&panel=&archived=), the router for same-origin links in rendered markdown, and the
// /api/boards cache invalidated after every write. No board logic lives here (test/unit/no_kanban_code_test.rb).
import { useCallback, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { apiDelete, apiGet, apiPost, apiUpload, invalidate, userEmail } from "../api";
import { projectPath } from "../lib/format";
import { pickYak } from "./YakLoader";
import {
  Board as KanbanBoard,
  PANELS,
  type Attachment,
  type BoardData,
  type BoardShapeData,
  type CardData,
  type KanbanApi,
  type MoveResult,
  type Panel,
} from "../vendor/agents_kanban";

const encSlug = (slug: string) => slug.split("/").map(encodeURIComponent).join("/");

export function busyyaksKanbanApi(): KanbanApi {
  return {
    board: (slug, { archived }) =>
      apiGet<BoardData>(`/api/projects/${encSlug(slug)}/board${archived ? "?archived=1" : ""}`),
    boardRev: (slug, { archived }) =>
      apiGet<{ rev: string }>(`/api/projects/${encSlug(slug)}/board/rev${archived ? "?archived=1" : ""}`).then(
        (r) => r.rev,
      ),
    card: (id) => apiGet<CardData>(`/api/cards/${id}`),
    cardRev: (id) => apiGet<{ rev: string }>(`/api/cards/${id}/rev`).then((r) => r.rev),
    createCard: (slug, body) => apiPost<CardData>(`/api/projects/${encSlug(slug)}/board`, body),
    move: (id, body) => apiPost<MoveResult>(`/api/cards/${id}/move`, body),
    update: (id, patch) => apiPost<CardData>(`/api/cards/${id}`, patch),
    assign: (id, assignee) => apiPost<CardData>(`/api/cards/${id}/assign`, { assignee }),
    archive: (id, archived) => apiPost<CardData>(`/api/cards/${id}/archive`, { archived }),
    setOwner: (id, session) => apiPost<CardData>(`/api/cards/${id}/owner`, { session }),
    approve: (id, approved) => apiPost<CardData>(`/api/cards/${id}/approve`, { approved }),
    dialogAnswer: (id, key) => apiPost<CardData>(`/api/cards/${id}/dialog-answer`, { key }),
    comment: (id, body) => apiPost<CardData>(`/api/cards/${id}/comment`, { body }),
    commentUpdate: (id, body) => apiPost<CardData>(`/api/comments/${id}`, { body }),
    commentDelete: (id) => apiDelete<CardData>(`/api/comments/${id}`),
    checklistCreate: (cardId, title) => apiPost<CardData>(`/api/cards/${cardId}/checklists`, { title }),
    checklistUpdate: (id, title) => apiPost<CardData>(`/api/checklists/${id}`, { title }),
    checklistDelete: (id) => apiDelete<CardData>(`/api/checklists/${id}`),
    itemCreate: (checklistId, body) => apiPost<CardData>(`/api/checklists/${checklistId}/items`, { body }),
    itemUpdate: (id, patch) => apiPost<CardData>(`/api/checklist-items/${id}`, patch),
    itemDelete: (id) => apiDelete<CardData>(`/api/checklist-items/${id}`),
    itemConvert: (id) => apiPost<CardData>(`/api/checklist-items/${id}/convert`, {}),
    labelCreate: (slug, name, color) => apiPost(`/api/projects/${encSlug(slug)}/labels`, { name, color }),
    labelUpdate: (id, patch) => apiPost(`/api/labels/${id}`, patch),
    labelDelete: (id) => apiDelete(`/api/labels/${id}`),
    attach: (cardId, file, onProgress) => {
      const form = new FormData();
      form.append("file", file, file.name);
      return apiUpload<{ attachment: Attachment }>(`/api/cards/${cardId}/attachments`, form, onProgress).then(
        (r) => r.attachment,
      );
    },
    attachmentDelete: (id) => apiDelete<CardData>(`/api/attachments/${id}`),
    markdownPreview: (body, inline) => apiPost<{ html: string }>("/api/markdown", { body, inline }).then((r) => r.html),
    boardShape: (slug) => apiGet<BoardShapeData>(`/api/projects/${encSlug(slug)}/workflow`),
    boardShapeSave: (slug, shape) => apiPost<BoardShapeData>(`/api/projects/${encSlug(slug)}/workflow`, shape),
    boardShapeReset: (slug) => apiDelete<BoardShapeData>(`/api/projects/${encSlug(slug)}/workflow`),
  };
}

export function ProjectBoard({ slug }: { slug: string }) {
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  // the engine wants (path) => void; BrowserRouter's navigate returns nothing to await. Stable, so the engine's host memo holds.
  const go = useCallback((path: string) => void navigate(path), [navigate]);
  const api = useMemo(busyyaksKanbanApi, []);
  const [yak] = useState(pickYak); // the vendored board's loading states (.spin) show this yak (spa.css)
  const panelParam = params.get("panel") as Panel;
  const view = {
    card: Number(params.get("card")) || null,
    panel: PANELS.includes(panelParam) ? panelParam : null,
    archived: params.get("archived") === "1",
  };
  const onView = (change: Partial<typeof view>) => {
    const p = new URLSearchParams(params);
    const set = (k: string, v: string | null) => (v == null ? p.delete(k) : p.set(k, v));
    if ("card" in change) set("card", change.card == null ? null : String(change.card));
    if ("panel" in change) set("panel", change.panel ?? null);
    if ("archived" in change) set("archived", change.archived ? "1" : null);
    setParams(p, { replace: !("card" in change) });
  };
  return (
    <div className="yak-board" data-yak={yak}>
      <KanbanBoard
        api={api}
        me={userEmail()}
        slug={slug}
        view={view}
        onView={onView}
        navigate={go}
        projectHref={projectPath(slug)}
        cardHref={(s, id) => `${projectPath(s)}?tab=board&card=${id}`}
        onChanged={() => invalidate("/api/boards")}
      />
    </div>
  );
}
