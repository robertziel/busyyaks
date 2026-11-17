// "Waiting for you", live, fixed bottom-right on every page (GET /api/waiting, refetched when GET /api/waiting/rev
// changes). Kind counters: one opaque plate with a segment per action, most important first —
// `? N to answer` · `eye N to review` (together = the total, the dock badge) · `clock N external` (CI-held + blocked on
// the world: shown, never counted as waiting for you). Each segment carries an avatar stack of its projects; a click
// opens the sheet on that kind's tab, its rows carry the project and the owner agent's live state. Loading, zero and
// a failed read are explicit states: a failed read shows the error, never 0 and never the last count.
import { useCallback, useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { createPortal } from "react-dom";
import { Link } from "react-router-dom";
import { apiGet, useResource } from "../api";
import { now, projectPath } from "../lib/format";
import { useLiveRev } from "../lib/live";
import { readWaiting } from "../lib/appBadge";
import {
  age,
  approvedLine,
  byKind,
  cardHref,
  KIND_LABEL,
  KINDS,
  nextKind,
  nextRow,
  segmentLabel,
  type Kind,
  type KindGroup,
  type KindRow,
  type Waiting,
} from "../lib/waiting";
import type { AgentsData, AgentState } from "../types";
import { why } from "../lib/agentRow";
import { ProjectIcon } from "./ProjectIcon";
import { LaunchFailureAlert } from "../vendor/agents_kanban";

// the owner agent of a waiting card, as /api/agents sees it right now; the reason it is blocked is the sidebar's own
const AGENT_LABEL: Record<AgentState, string> = {
  blocked: "blocked",
  review: "PR review",
  working: "working",
  finished: "finished",
  idle: "idle",
  unknown: "unknown",
};
function agentLine(owner: string | null, agents: AgentsView): { cls: string; text: string; why: string | null } {
  if (!owner) return { cls: "none", text: "no agent", why: null };
  if (agents.error) return { cls: "err", text: `${owner} · agents: ${agents.error}`, why: null };
  if (!agents.data) return { cls: "none", text: `${owner} · …`, why: null };
  const s = agents.data.groups.flatMap((g) => g.sessions).find((x) => x.name === owner);
  if (!s) return { cls: "gone", text: `${owner} · not running`, why: null };
  return { cls: s.state, text: `${owner} · ${AGENT_LABEL[s.state]}`, why: s.state === "blocked" ? why(s) : null };
}
export type AgentsView = { data: AgentsData | null; error: string | null };

// the glyph of each kind: the cue that does not depend on colour
export function KindGlyph({ kind }: { kind: Kind }) {
  return (
    <svg className="ww-glyph" viewBox="0 0 12 12" aria-hidden="true">
      {kind === "ask" && (
        <>
          <path
            d="M3.6 4.3a2.4 2.4 0 1 1 3.6 2.1c-.8.5-1.2.9-1.2 1.7"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeLinecap="round"
          />
          <circle cx="6" cy="10.4" r="1.1" fill="currentColor" />
        </>
      )}
      {kind === "review" && (
        <>
          <path
            d="M.8 6C2 3.7 3.8 2.5 6 2.5S10 3.7 11.2 6C10 8.3 8.2 9.5 6 9.5S2 8.3.8 6Z"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinejoin="round"
          />
          <circle cx="6" cy="6" r="1.7" fill="currentColor" />
        </>
      )}
      {kind === "approved" && (
        <path
          d="M2 6.3 4.8 9 10 3.2"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      )}
      {kind === "external" && (
        <>
          <circle cx="6" cy="6" r="4.7" fill="none" stroke="currentColor" strokeWidth="1.4" />
          <path d="M6 3.4V6l1.8 1.2" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </>
      )}
    </svg>
  );
}

// the projects of a segment: up to 3 avatars (2 under 600 px wide), the rest as "+N" — both counts are rendered and the
// stylesheet shows the one for the width, so the plate never grows with the project count. Inside the segment's
// button: an avatar's click is the segment's click.
const STACK = 3;
const STACK_NARROW = 2;
function Stack({ g }: { g: KindGroup }) {
  const n = g.projects.length;
  return (
    <span className="ww-stack" aria-hidden="true">
      {g.projects.slice(0, STACK).map((p, i) => (
        <span key={p.slug} className={i >= STACK_NARROW ? "ww-av ww-av-wide" : "ww-av"}>
          <ProjectIcon slug={p.slug} icon={p.icon} size={18} letters={1} />
        </span>
      ))}
      {n > STACK && <span className="ww-more ww-more-wide">+{n - STACK}</span>}
      {n > STACK_NARROW && <span className="ww-more ww-more-narrow">+{n - STACK_NARROW}</span>}
    </span>
  );
}

// a row's second line: why it waits on the world (external tab: the block reason, the CI hold — a held gate card also
// carries its handoff text, which is not why it waits), else the question or what the agent says to check
function rowLine(r: KindRow, kind: Kind): string | null {
  const c = r.card;
  if (kind === "external") return c.blocked_first_line ?? (c.gate_hold ? `held: ${c.gate_hold}` : null);
  if (kind === "approved") return approvedLine(c);
  // approved, but no session owns it to carry it on: it waits for you — say why first
  if (c.approved && !c.carried_on && !c.needs_operator) return "approved · no agent";
  return c.question_first_line ?? c.handoff_first_line ?? null;
}

// what an open sheet shows: the rows of a good read with at least one segment · "read failed: <reason>" after a failed
// read (never the last rows or counts) · nothing (no read yet, or every count at 0) — then the widget closes it, so
// "open" never lingers behind a hidden sheet (it would swallow the next click and reopen by itself)
export type SheetMode = "list" | "error" | null;
export const sheetMode = (data: Waiting | null, error: string | null): SheetMode =>
  error ? "error" : data !== null && KINDS.some((k) => byKind(data)[k].count > 0) ? "list" : null;

export type WaitingState = "error" | "loading" | "zero" | "some";
export const waitingState = (data: Waiting | null, error: string | null): WaitingState =>
  error ? "error" : !data ? "loading" : data.total === 0 ? "zero" : "some";

type Focusable = { focus: () => void };
type KeyEv = {
  key: string;
  preventDefault: () => void;
  target: unknown;
  currentTarget: { querySelectorAll: (q: string) => ArrayLike<Focusable> };
};
// ↑/↓/Home/End between the sheet's rows (the focused row = the event's target link)
export function rowKey(e: KeyEv) {
  const links = Array.from(e.currentTarget.querySelectorAll("a"));
  const next = nextRow(links.indexOf(e.target as Focusable), links.length, e.key);
  if (next === null) return;
  e.preventDefault();
  links[next]?.focus();
}

export function WaitingView({
  data,
  error,
  open,
  kind = "ask",
  at,
  agents = { data: null, error: null },
  onSegment,
  onTab,
  onRow,
  segmentRef,
}: {
  data: Waiting | null;
  error: string | null;
  open: boolean;
  kind?: Kind;
  at: number;
  agents?: AgentsView;
  onSegment?: (k: Kind) => void;
  onTab?: (k: Kind) => void;
  onRow?: () => void;
  segmentRef?: (el: HTMLButtonElement | null, k: Kind) => void;
}) {
  const state = waitingState(data, error);
  const groups = data && !error ? byKind(data) : null;
  const shown = groups ? KINDS.filter((k) => groups[k].count > 0) : [];
  const mode = open ? sheetMode(data, error) : null;
  const panelOpen = mode !== null;
  const tabKey = (e: ReactKeyboardEvent<HTMLButtonElement>) => {
    if (e.key === "ArrowDown") {
      // from the tabs down into the rows
      const first = e.currentTarget.closest(".ww-panel")?.querySelector<HTMLAnchorElement>("#ww-list a");
      if (!first) return;
      e.preventDefault();
      first.focus();
      return;
    }
    const next = nextKind(kind, e.key);
    if (!next) return;
    e.preventDefault();
    onTab?.(next);
    e.currentTarget.parentElement?.querySelector<HTMLButtonElement>(`[data-kind="${next}"]`)?.focus();
  };
  const rows = groups ? groups[kind].rows : [];
  return (
    <>
      <div className={`ww-plate ww-${state}`} role="group" aria-label="Waiting for you">
        {state === "error" && (
          <span className="ww-err" role="status" title={error ?? undefined}>
            <i className="ww-dot" aria-hidden="true" /> live · error <small>{error}</small>
          </span>
        )}
        {state === "loading" && (
          <span className="ww-note ww-loading" role="status">
            <i className="ww-dot" aria-hidden="true" /> loading…
          </span>
        )}
        {state === "zero" && (
          <span className="ww-note ww-none" role="status">
            0 waiting for you
          </span>
        )}
        {groups &&
          shown.map((k) => {
            const g = groups[k];
            const label = segmentLabel(g);
            return (
              <button
                key={k}
                type="button"
                ref={(el) => segmentRef?.(el, k)}
                className={`ww-seg ww-seg-${k}`}
                data-kind={k}
                aria-label={label}
                title={label}
                aria-expanded={panelOpen && kind === k}
                aria-controls={panelOpen ? "ww-panel" : undefined}
                onClick={() => onSegment?.(k)}
              >
                <KindGlyph kind={k} />
                <span className="ww-num">{g.count}</span>
                <span className="ww-lab">{KIND_LABEL[k]}</span>
                <Stack g={g} />
              </button>
            );
          })}
      </div>
      {mode === "error" && (
        <div className="ww-panel" id="ww-panel" role="region" aria-label="Cards waiting">
          <div className="ww-sheet">
            <p className="ww-failed" role="alert">
              read failed: {error}
            </p>
          </div>
        </div>
      )}
      {mode === "list" && groups && (
        <div className="ww-panel" id="ww-panel" role="region" aria-label="Cards waiting">
          <div className="ww-tabs" role="tablist" aria-label="Kind">
            {KINDS.map((k) => (
              <button
                key={k}
                type="button"
                role="tab"
                id={`ww-tab-${k}`}
                data-kind={k}
                className={`ww-tab ww-tab-${k}`}
                aria-selected={k === kind}
                aria-label={`${groups[k].count} ${KIND_LABEL[k]}`}
                aria-controls="ww-list"
                tabIndex={k === kind ? 0 : -1}
                onClick={() => onTab?.(k)}
                onKeyDown={tabKey}
              >
                <KindGlyph kind={k} />
                <span className="ww-tab-n">{groups[k].count}</span> <span className="ww-tab-lab">{KIND_LABEL[k]}</span>
              </button>
            ))}
          </div>
          <div className="ww-sheet" role="tabpanel" id="ww-list" aria-labelledby={`ww-tab-${kind}`}>
            {rows.length === 0 ? (
              <p className="ww-empty">Nothing {KIND_LABEL[kind]}</p>
            ) : (
              <ul onKeyDown={rowKey}>
                {rows.map((r) => {
                  const c = r.card;
                  const a = agentLine(c.owner_session, agents);
                  const line = rowLine(r, kind);
                  return (
                    <li key={c.id} className={`ww-row ww-k-${kind}`}>
                      <Link to={cardHref(r.slug, c.id)} data-card-id={c.id} onClick={onRow}>
                        <span className="ww-id">#{c.id}</span>
                        <span className="ww-title">{c.title}</span>
                        <span className="ww-age">{age(c.since, at)}</span>
                        <span className="ww-meta">
                          <span className="ww-proj" title={r.slug}>
                            <ProjectIcon slug={r.slug} icon={r.icon} size={14} />
                            {r.name}
                          </span>
                          <span className="ww-col">{c.column_label}</span>
                          {line && <span className="ww-q">{line}</span>}
                        </span>
                        <span className={`ww-agent ag-${a.cls}`}>
                          <i aria-hidden="true" />
                          <span>{a.text}</span>
                          {a.why && <em>{a.why}</em>}
                        </span>
                      </Link>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </div>
      )}
    </>
  );
}

// Escape closes the sheet and returns focus to the segment of the kind shown (else the first segment still there:
// that kind's count may have dropped to 0 since)
export function escapeFocus<T>(segments: Map<Kind, T>, kind: Kind): T | undefined {
  return segments.get(kind) ?? KINDS.map((k) => segments.get(k)).find((s) => s !== undefined);
}

// While the sheet is open: Escape closes it (then onEscape: focus back to its segment); a press outside the widget
// closes it. With the card list shown (swallow) the click that follows is swallowed: it must not also click what lies
// underneath. With only the "read failed" row shown nothing is to be dismissed by mistake, so the page's click goes
// through. → the cleanup.
export function sheetListeners(
  doc: EventTarget,
  win: EventTarget & { setTimeout: (f: () => void, ms: number) => unknown },
  inside: (target: unknown) => boolean,
  close: () => void,
  onEscape: () => void,
  swallow: boolean,
): () => void {
  const key = (e: Event) => {
    if ((e as KeyboardEvent).key !== "Escape") return;
    close();
    onEscape();
  };
  const down = (e: Event) => {
    if (inside(e.target)) return;
    close();
    if (!swallow) return;
    const eat = (c: Event) => {
      c.preventDefault();
      c.stopPropagation();
    };
    win.addEventListener("click", eat, { capture: true, once: true });
    win.setTimeout(() => win.removeEventListener("click", eat, { capture: true }), 400);
  };
  doc.addEventListener("keydown", key);
  doc.addEventListener("pointerdown", down);
  return () => {
    doc.removeEventListener("keydown", key);
    doc.removeEventListener("pointerdown", down);
  };
}

export function WaitingWidget() {
  const [data, setData] = useState<Waiting | null>(null);
  const [fetchErr, setFetchErr] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<Kind>("ask"); // the segment clicked = the sheet's tab
  const [at, setAt] = useState(now());
  const box = useRef<HTMLDivElement>(null);
  const segments = useRef(new Map<Kind, HTMLButtonElement>());

  const load = useCallback(() => {
    // the installed app's dock badge follows each read: the total, or unknown on a failure
    void readWaiting(
      () => apiGet<Waiting>("/api/waiting"),
      (w) => {
        setData(w);
        setFetchErr(null);
      },
      setFetchErr,
    );
  }, []);
  useEffect(load, [load]);
  const live = useLiveRev("/api/waiting/rev", load, { every: 4000 });
  useEffect(() => setAt(now()), [live.at, data]);

  const error = fetchErr ?? live.error;
  // the sheet as shown: the listeners follow it, never the bare flag
  const mode = open ? sheetMode(data, error) : null;
  const shown = mode !== null;
  useEffect(() => {
    if (open && !shown) setOpen(false);
  }, [open, shown]);
  useEffect(() => {
    if (!shown) return;
    return sheetListeners(
      document,
      window,
      (t) => box.current?.contains(t as Node) ?? false,
      () => setOpen(false),
      () => escapeFocus(segments.current, kind)?.focus(),
      mode === "list",
    );
  }, [shown, mode, kind]);

  // the owner agents' live state, only while the tickets are shown (the sidebar polls the same cached resource)
  const ag = useResource<AgentsData>(shown ? "/api/agents" : null, { every: 10_000 });
  const agents: AgentsView = { data: ag.data ?? null, error: ag.error ? ag.error.message : null };

  // a segment opens the sheet on its kind; the same segment again closes it
  const onSegment = (k: Kind) => {
    setOpen((o) => !(o && kind === k));
    setKind(k);
  };
  const segmentRef = useCallback((el: HTMLButtonElement | null, k: Kind) => {
    if (el) segments.current.set(k, el);
    else segments.current.delete(k);
  }, []);

  return (
    <div className="waiting-widget" ref={box}>
      <WaitingView
        data={data}
        error={error}
        open={open}
        kind={kind}
        at={at}
        agents={agents}
        onSegment={onSegment}
        onTab={setKind}
        onRow={() => setOpen(false)}
        segmentRef={segmentRef}
      />
      {/* a session the board started never came up: a modal over every page, not a line on the card */}
      {data &&
        createPortal(
          <LaunchFailureAlert
            failures={data.launch_failures}
            leadEnds={data.lead_ends}
            storageKey="busyyaks.launch-failure-seen"
            projectHref={(slug) => `${projectPath(slug)}?tab=board`}
          />,
          document.body,
        )}
    </div>
  );
}
