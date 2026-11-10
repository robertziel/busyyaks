// "N waiting for you", live, fixed bottom-right on every page: the cards in the board config's `waiting`
// columns over every project (GET /api/waiting), refetched when GET /api/waiting/rev changes. No capsule —
// a small number circle on the left (the total; click → every ticket) and one round bubble per project (its logo, ring
// + glow in its most important input's colour, most important + latest on the right; click → that project's tickets,
// each with its owner agent's live state and what blocks it). Bubbles that do not fit fold into a "+N" bubble on the
// left (the least important ones). A failed poll shows the error instead of the numbers — never stale counts as current.
import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";
import { Link } from "react-router-dom";
import { apiGet, useResource } from "../api";
import { now, projectPath } from "../lib/format";
import { useLiveRev } from "../lib/live";
import {
  age,
  bubbles,
  cardHref,
  LEVEL_COLOR,
  LEVEL_LABEL,
  pillTotal,
  ring,
  topCount,
  totals,
  type BubbleLevel,
  type Waiting,
} from "../lib/waiting";
import type { AgentsData, AgentState } from "../types";
import { why } from "./Agents";
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

// the values on hover / keyboard focus: a count per status in its colour, and the newest card's age
function Tip({
  head,
  counts,
  newest,
}: {
  head: string;
  counts: { asks: number; reviews: number; others: number };
  newest?: string;
}) {
  const rows: [BubbleLevel, number][] = (
    [
      ["ask", counts.asks],
      ["review", counts.reviews],
      ["other", counts.others],
    ] as [BubbleLevel, number][]
  ).filter(([, n]) => n > 0);
  return (
    <span className="ww-tip" role="tooltip">
      <b>{head}</b>
      {rows.map(([lv, n]) => (
        <span key={lv} className="ww-tip-row">
          <i style={{ background: LEVEL_COLOR[lv] }} aria-hidden="true" />
          <em>{n}</em> {LEVEL_LABEL[lv]}
        </span>
      ))}
      {newest && <small>newest {newest}</small>}
    </span>
  );
}

export function WaitingView({
  data,
  error,
  open,
  focus = null,
  at,
  fit = Infinity,
  agents = { data: null, error: null },
  onToggle,
  onFocus,
  openerRef,
}: {
  data: Waiting | null;
  error: string | null;
  open: boolean;
  focus?: string | null;
  at: number;
  fit?: number;
  agents?: AgentsView;
  onToggle?: () => void;
  onFocus?: (slug: string) => void;
  openerRef?: (el: HTMLButtonElement | null, key: string) => void;
}) {
  const state = error ? "error" : !data ? "loading" : data.total === 0 ? "zero" : "some";
  const all = data ? bubbles(data) : [];
  // the panel lists projects in the bubbles' order, most important first
  const order = [...all].reverse().map((b) => b.slug);
  const shown = data
    ? order.map((slug) => data.projects.find((p) => p.slug === slug)!).filter((p) => !focus || p.slug === focus)
    : [];
  // bubbles that fit: the most important ones (the right end); the rest fold into "+N" on the left
  const folded = all.length > fit ? all.slice(0, all.length - Math.max(1, fit - 1)) : [];
  const visible = all.slice(folded.length);
  const top: BubbleLevel | "zero" = all.some((b) => b.level === "ask")
    ? "ask"
    : all.some((b) => b.level === "review")
      ? "review"
      : all.length
        ? "other"
        : "zero";
  const panelOpen = open && state === "some" && shown.length > 0;
  return (
    <>
      <div className={`ww-pill ww-${state}`} title={error ?? undefined}>
        {state === "error" ? (
          <span className="ww-err" role="status">
            <i className="ww-dot" aria-hidden="true" /> live · error <small>{error}</small>
          </span>
        ) : (
          <button
            type="button"
            ref={(el) => openerRef?.(el, "")}
            className={`ww-total ww-t-${state === "loading" ? "loading" : top}`}
            aria-label={state === "loading" ? "loading waiting cards" : `${pillTotal(data!)}: show all`}
            aria-expanded={panelOpen && !focus}
            aria-controls={panelOpen ? "ww-panel" : undefined}
            onClick={onToggle}
          >
            <span
              className="ww-face"
              style={state === "some" ? ({ "--ww-ring": ring(totals(data!)) } as CSSProperties) : undefined}
            >
              {state === "loading" ? "…" : data!.total}
            </span>
            {state === "some" && <Tip head={pillTotal(data!)} counts={totals(data!)} />}
          </button>
        )}
        {state === "some" && (
          <span className="ww-chips">
            {folded.length > 0 && (
              <button
                type="button"
                className="ww-chip ww-more"
                aria-label={`${folded.length} more projects: show all`}
                onClick={onToggle}
              >
                <span
                  className="ww-face"
                  style={
                    {
                      "--ww-ring": ring({
                        asks: sum(folded, "asks"),
                        reviews: sum(folded, "reviews"),
                        others: sum(folded, "others"),
                      }),
                    } as CSSProperties
                  }
                >
                  +{folded.length}
                </span>
                <Tip
                  head={folded.map((b) => b.name).join(", ")}
                  counts={{ asks: sum(folded, "asks"), reviews: sum(folded, "reviews"), others: sum(folded, "others") }}
                />
              </button>
            )}
            {visible.map((b) => (
              <button
                key={b.slug}
                type="button"
                ref={(el) => openerRef?.(el, b.slug)}
                className={`ww-chip ww-${b.level}`}
                aria-label={b.title}
                aria-expanded={panelOpen && focus === b.slug}
                aria-controls={panelOpen ? "ww-panel" : undefined}
                onClick={() => onFocus?.(b.slug)}
              >
                <span className="ww-face" style={{ "--ww-ring": ring(b) } as CSSProperties}>
                  <ProjectIcon slug={b.slug} icon={b.icon} size={26} />
                  <b className="ww-n">
                    {b.level === "ask" && <span aria-hidden="true">?</span>}
                    {topCount(b)}
                  </b>
                </span>
                <Tip
                  head={b.slug}
                  counts={b}
                  newest={b.latest != null ? age(new Date(b.latest).toISOString(), at) : undefined}
                />
              </button>
            ))}
          </span>
        )}
      </div>
      {panelOpen && (
        <div
          className="ww-panel"
          id="ww-panel"
          role="region"
          aria-label={focus ? `Cards waiting for you in ${focus}` : "Cards waiting for you"}
        >
          <div className="ww-sheet">
            {shown.map((p) => (
              <section key={p.slug} className="ww-group">
                <h4>
                  <span className="ww-slug">
                    <ProjectIcon slug={p.slug} icon={p.icon} size={14} /> {p.slug}
                  </span>{" "}
                  <b>{p.count}</b>
                </h4>
                <ul>
                  {p.cards.map((c) => {
                    const a = agentLine(c.owner_session, agents);
                    return (
                      <li key={c.id} className={`ww-row ww-k-${c.kind}`}>
                        <Link to={cardHref(p.slug, c.id)}>
                          <span className="ww-id">#{c.id}</span>
                          <span className="ww-title">{c.title}</span>
                          <span className="ww-age">{age(c.since, at)}</span>
                          <span className="ww-meta">
                            <span className="ww-col">{c.column_label}</span>
                            {(c.question_first_line ?? c.handoff_first_line) && (
                              <span className="ww-q">{c.question_first_line ?? c.handoff_first_line}</span>
                            )}
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
              </section>
            ))}
          </div>
        </div>
      )}
    </>
  );
}

const sum = (bs: { asks: number; reviews: number; others: number }[], k: "asks" | "reviews" | "others") =>
  bs.reduce((a, b) => a + b[k], 0);

// how many bubbles fit beside the total at this width (the total + 16 px gutters; touch bubbles are 44 px)
function fitFor(width: number, touch: boolean): number {
  const step = touch ? 48 : 42;
  return Math.max(1, Math.floor((width - 32 - (touch ? 52 : 42)) / step));
}
const touchScreen = () => window.matchMedia("(hover: none)").matches;

export function WaitingWidget() {
  const [data, setData] = useState<Waiting | null>(null);
  const [fetchErr, setFetchErr] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [focus, setFocusSlug] = useState<string | null>(null); // the bubble clicked: only its project's tickets
  const [at, setAt] = useState(now());
  const [fit, setFit] = useState(() => fitFor(window.innerWidth, touchScreen()));
  const box = useRef<HTMLDivElement>(null);
  const openers = useRef(new Map<string, HTMLButtonElement>());

  const load = useCallback(() => {
    apiGet<Waiting>("/api/waiting")
      .then((w) => {
        setData(w);
        setFetchErr(null);
      })
      .catch((e: unknown) => setFetchErr(e instanceof Error ? e.message : String(e)));
  }, []);
  useEffect(load, [load]);
  const live = useLiveRev("/api/waiting/rev", load, { every: 4000 });
  useEffect(() => setAt(now()), [live.at, data]);

  useEffect(() => {
    const r = () => setFit(fitFor(window.innerWidth, touchScreen()));
    window.addEventListener("resize", r);
    return () => window.removeEventListener("resize", r);
  }, []);

  useEffect(() => {
    if (!open) return;
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      setOpen(false);
      openers.current.get(focus ?? "")?.focus(); // back to the button that opened it
    };
    // an outside press closes the panel and is swallowed: it must not also click what lies underneath
    const down = (e: PointerEvent) => {
      if (box.current?.contains(e.target as Node)) return;
      setOpen(false);
      const swallow = (c: MouseEvent) => {
        c.preventDefault();
        c.stopPropagation();
      };
      window.addEventListener("click", swallow, { capture: true, once: true });
      window.setTimeout(() => window.removeEventListener("click", swallow, { capture: true }), 400);
    };
    document.addEventListener("keydown", key);
    document.addEventListener("pointerdown", down);
    return () => {
      document.removeEventListener("keydown", key);
      document.removeEventListener("pointerdown", down);
    };
  }, [open, focus]);

  // the owner agents' live state, only while the tickets are shown (the sidebar polls the same cached resource)
  const ag = useResource<AgentsData>(open ? "/api/agents" : null, { every: 10_000 });
  const agents: AgentsView = { data: ag.data ?? null, error: ag.error ? ag.error.message : null };

  // the total (or "+N") → every project's tickets; a bubble → that project's; the same click again closes
  const toggleAll = () => {
    setOpen((o) => !(o && !focus));
    setFocusSlug(null);
  };
  const toggleFocus = (slug: string) => {
    setOpen((o) => !(o && focus === slug));
    setFocusSlug(slug);
  };
  const openerRef = useCallback((el: HTMLButtonElement | null, k: string) => {
    if (el) openers.current.set(k, el);
    else openers.current.delete(k);
  }, []);

  const error = fetchErr ?? live.error;
  return (
    <div className="waiting-widget" ref={box} onClick={(e) => (e.target as HTMLElement).closest("a") && setOpen(false)}>
      <WaitingView
        data={data}
        error={error}
        open={open}
        focus={focus}
        at={at}
        fit={fit}
        agents={agents}
        onToggle={toggleAll}
        onFocus={toggleFocus}
        openerRef={openerRef}
      />
      {/* a session the board started never came up: a modal over every page, not a line on the card */}
      {data &&
        createPortal(
          <LaunchFailureAlert
            failures={data.launch_failures}
            storageKey="busyyaks.launch-failure-seen"
            projectHref={(slug) => `${projectPath(slug)}?tab=board`}
          />,
          document.body,
        )}
    </div>
  );
}
