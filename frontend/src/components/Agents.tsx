// Agents sidebar: /api/agents every 10 s; open sessions stay open across refreshes and reload their team
// (subagents · workflows · tasks) on every poll. herdr's states: blocked (needs input: the job is stopped on a
// dialog / permission prompt — answered here —, a card question, the collector's waiting_for) · review (its card waits in
// Human Check: a PR to review) · done (finished since you last opened it) · working · idle · unknown. The rows that wait
// for you are highlighted whole. Filters All / Needs you / Working / Teams, remembered.
// "done" said nothing about the work — it is now `unread` (a dot: the turn ended since you last opened it;
// opening the row marks it seen) and `finished` is a state the CARDS decide: every card it owns sits in a done column.
// Each row lists its open cards by column label (`#3 In progress`), `+N done`, or `no cards`.
// each project shows its active sessions only; the "N idle" toggle in its header unfolds the rest (remembered per project), and
// rows fold in and out with a height + fade transition (lib/agentFold.ts decides what is visible).
import { ClaudeLink, CopyChip, ItermCopy, TerminalLink } from "./Copy";
import { ProjectIcon } from "./ProjectIcon";
import { ReapButton } from "./Reap";
import { YakLoader } from "./YakLoader";
import { useEffect, useState, type SyntheticEvent } from "react";
import { Link } from "react-router-dom";
import { ApiError, apiPost, invalidate, useResource } from "../api";
import { fold, groupKey, type Filter } from "../lib/agentFold";
import { ago, projectPath } from "../lib/format";
import * as store from "../lib/store";
import type { AgentDialog, AgentSession, AgentsData, AgentState, TeamData } from "../types";

const FILTERS: [Filter, string][] = [
  ["all", "All"],
  ["you", "Needs you"],
  ["busy", "Working"],
  ["team", "Teams"],
];
const LABEL: Record<AgentState, string> = {
  blocked: "needs input",
  review: "PR review",
  working: "working",
  finished: "finished",
  idle: "idle",
  unknown: "unknown",
};
const BADGE = new Set<AgentState>(["blocked", "review", "finished"]);

export type AgentTotals = { busy: number; blocked: number; review: number; unread: number };

export function Agents({ onTotals }: { onTotals: (t: AgentTotals | null) => void }) {
  const { data, error, loading } = useResource<AgentsData>("/api/agents", { every: 10_000 });
  const [filter, setFilterState] = useState<Filter>(() => {
    const f = store.get("busyyaks.agfilter");
    return f === "you" || f === "busy" || f === "team" ? f : "all";
  });
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  const [unfolded, setUnfolded] = useState<Set<string>>(
    () => new Set(store.getJSON<string[]>("busyyaks.agunfold", [])),
  );
  const unfold = (k: string) =>
    setUnfolded((prev) => {
      const n = new Set(prev);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      store.set("busyyaks.agunfold", JSON.stringify([...n]));
      return n;
    });

  useEffect(
    () =>
      onTotals(
        data
          ? {
              busy: data.totals.busy,
              blocked: data.totals.blocked,
              review: data.totals.review,
              unread: data.totals.unread,
            }
          : null,
      ),
    [data, onTotals],
  );

  const setFilter = (f: Filter) => {
    setFilterState(f);
    store.set("busyyaks.agfilter", f);
  };
  const toggle = (s: AgentSession) => (e: SyntheticEvent<HTMLDetailsElement>) => {
    const isOpen = e.currentTarget.open;
    if (isOpen && s.unread)
      void apiPost("/api/agents/seen", { key: s.key }).then(
        () => invalidate("/api/agents"),
        () => undefined,
      );
    setOpen((prev) => {
      if (prev.has(s.key) === isOpen) return prev;
      const n = new Set(prev);
      if (isOpen) n.add(s.key);
      else n.delete(s.key);
      return n;
    });
  };

  if (!data) {
    return (
      <>
        <div className="ag-head">
          <b>Agents</b>
          {loading && (
            <span className="ag-sum ag-loading" role="status">
              <YakLoader small /> loading…
            </span>
          )}
        </div>
        {error && (
          <p className="ag-err">
            <i className="dot bad" /> {error.message}
          </p>
        )}
      </>
    );
  }

  const t = data.totals;
  return (
    <>
      <div className="ag-head">
        <b>Agents</b>
        <span className="ag-sum">
          <b>{t.sessions}</b> sessions · <b className={t.blocked > 0 ? "bad" : ""}>{t.blocked}</b> need input ·{" "}
          <b className={t.review > 0 ? "rev" : ""}>{t.review}</b> PR review ·{" "}
          <b className={t.unread > 0 ? "done" : ""}>{t.unread}</b> unread · <b>{t.finished}</b> finished ·{" "}
          <b className={t.busy > 0 ? "ok" : ""}>{t.busy}</b> working · <b>{t.subagents}</b> subagents
        </span>
      </div>
      <div className="ag-filter" role="group" aria-label="Agent filter">
        {FILTERS.map(([k, label]) => (
          <button key={k} type="button" className="chip" aria-pressed={filter === k} onClick={() => setFilter(k)}>
            {label}
            {k === "you" && t.you > 0 && <b className="ag-n">{t.you}</b>}
          </button>
        ))}
        <span className="spacer" />
        <ReapButton />
      </div>
      {error && (
        <p className="ag-err">
          <i className="dot bad" /> refresh failed: {error.message} · showing the last snapshot
        </p>
      )}
      {(data.stale || data.collector_error) && (
        <p className="ag-err">
          <i className="dot bad" /> collector {data.stale ? `snapshot ${Math.round(data.age_s)}s old` : ""}{" "}
          {data.collector_error ?? ""}
        </p>
      )}
      <div className="ag-groups">
        {data.groups.map((g) => {
          const k = groupKey(g);
          const f = fold(g, filter, open, unfolded.has(k));
          if (!f.shown) return null;
          return (
            <section className={`ag-group${f.activeCount === 0 ? " ag-quiet" : ""}`} key={k}>
              <h5 className={`st-${g.state}`}>
                <span className="ag-gl">
                  <i className="ag-gdot" title={LABEL[g.state]} />
                  {g.slug ? (
                    <Link to={projectPath(g.slug)} className="pname">
                      <ProjectIcon slug={g.slug} icon={g.icon} size={14} />
                      {g.label}
                    </Link>
                  ) : (
                    g.label
                  )}
                </span>
                {f.idleCount > 0 ? (
                  <button
                    type="button"
                    className="ag-more"
                    aria-expanded={f.unfolded}
                    title={
                      f.unfolded ? `Hide the ${f.idleCount} idle sessions` : `Show the ${f.idleCount} idle sessions`
                    }
                    onClick={() => unfold(k)}
                  >
                    <span>
                      {f.activeCount > 0 && (
                        <>
                          <b>{f.activeCount}</b> ·{" "}
                        </>
                      )}
                      {f.idleCount} idle
                    </span>
                    <i className="ag-chev" aria-hidden />
                  </button>
                ) : (
                  <span className="ag-gn">{f.activeCount}</span>
                )}
              </h5>
              {f.rows.map(({ s, visible }) => (
                <div
                  key={s.key}
                  className={`ag-row${visible ? "" : " folded"}`}
                  aria-hidden={visible ? undefined : true}
                >
                  <div className="ag-clip">
                    <details
                      className={`ag-s st-${s.state}${s.unread ? " ag-unread" : ""}`}
                      open={open.has(s.key)}
                      onToggle={toggle(s)}
                    >
                      <summary
                        title={`${LABEL[s.state]}${s.unread ? " · unread" : ""}${s.state_by ? ` — ${s.state_by}` : ""}`}
                      >
                        <i className="ag-dot" />
                        <span className="ag-main">
                          <span className="ag-name">
                            {s.name}
                            {s.attached && (
                              <>
                                {" "}
                                <i className="ag-att" title="attached">
                                  ●
                                </i>
                              </>
                            )}
                          </span>
                          <span className="ag-title">
                            {s.title ?? (s.cwd ? s.cwd.split("/").slice(-2).join("/") : "—")}
                          </span>
                          {(s.state === "blocked" || s.state === "review") && <span className="ag-why">{why(s)}</span>}
                          {cardLine(s) && <span className="ag-cards">{cardLine(s)}</span>}
                        </span>
                        <span className="ag-meta">
                          {BADGE.has(s.state) && <span className={`ag-badge st-${s.state}`}>{LABEL[s.state]}</span>}
                          {s.subagents > 0 && (
                            <span className="ag-team" title="subagents running">
                              {s.subagents}
                            </span>
                          )}
                          <span className="ag-eng">{s.engines.join("·")}</span>
                          <span className="ag-ago">{ago(s.activity)}</span>
                        </span>
                      </summary>
                      <div className="ag-body">
                        {s.dialogs.map((d) => (
                          <DialogBox key={d.hash} s={s} d={d} />
                        ))}
                        {s.asks.map((a) => (
                          <Link key={a.id} className="ag-ask" to={a.path}>
                            <b>card #{a.id}</b> {a.title}
                            {a.question && <span>{a.question}</span>}
                          </Link>
                        ))}
                        {s.reviews.map((r) => (
                          <span key={r.id} className="ag-rev">
                            <Link to={r.path}>
                              <b>card #{r.id}</b> {r.title}
                            </Link>
                            {r.pr_url && (
                              <a href={r.pr_url} target="_blank" rel="noreferrer">
                                PR ↗
                              </a>
                            )}
                          </span>
                        ))}
                        {s.waiting_for.map((w, i) => (
                          <p className="ag-wait" key={i}>
                            waiting: {w}
                          </p>
                        ))}
                        {s.screen_errors.map((e, i) => (
                          <p className="ag-err" key={i}>
                            <i className="dot bad" /> screen: {e}
                          </p>
                        ))}
                        {s.state_by && (
                          <p className="ag-facts">
                            {LABEL[s.state]} · {s.state_by}
                          </p>
                        )}
                        <p className="ag-facts">
                          <CopyChip text={`tmux attach -t ${s.name}`} />
                          <ClaudeLink url={s.claude_url} name={s.name} />
                          <ItermCopy command={s.ssh_attach} />
                          <TerminalLink url={s.terminal_url} name={s.name} />
                          {s.model && <> · {s.model}</>}
                        </p>
                        <div className="ag-teamlist" aria-live="polite">
                          {open.has(s.key) && <Team session={s.name} socket={s.socket} />}
                        </div>
                      </div>
                    </details>
                  </div>
                </div>
              ))}
            </section>
          );
        })}
      </div>
      <p className="ag-foot muted">agent_engines · snapshot {Math.round(data.age_s)}s</p>
    </>
  );
}

// the cards it owns that are not done, by their column's label, then how many are — or that it owns none
export function cardLine(s: AgentSession): string {
  if (!s.cards_known) return "not registered: cards unknown";
  const shown = new Set([...s.asks, ...s.reviews].map((c) => c.id)); // already on the why line
  const parts = s.cards
    .filter((c) => !shown.has(c.id))
    .map((c) => `#${c.id} ${c.column_label}${c.gate_hold ? " · waiting for CI" : ""}`);
  if (s.cards_finished > 0) parts.push(`+${s.cards_finished} done`);
  return parts.length ? parts.join(" · ") : shown.size ? "" : "no cards";
}

// the one line under a blocked session's title: what it waits for
export function why(s: AgentSession): string {
  const d = s.dialogs[0];
  if (d) return d.question || d.command || "a dialog is on its screen";
  if (s.waiting_for[0]) return s.waiting_for[0];
  const a = s.asks[0];
  if (a) return `card #${a.id}: ${a.question || a.title}`;
  const r = s.reviews[0];
  if (r) return `card #${r.id} in review: ${r.title}`;
  return s.state_by ?? "waiting";
}

// A dialog on the session's screen, answered from here: the host presses the key only while the screen still shows
// this exact dialog (hash), else it refuses and nothing is typed. Free-text choices are shown, never clickable.
function DialogBox({ s, d }: { s: AgentSession; d: AgentDialog }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const press = async (key: string) => {
    setBusy(key);
    setErr(null);
    try {
      await apiPost("/api/agents/answer", { session: s.name, socket: s.socket, hash: d.hash, key });
      invalidate("/api/agents");
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };
  return (
    <div className="ag-dialog">
      {d.command && <pre>{d.command}</pre>}
      {d.question && <p className="ag-q">{d.question}</p>}
      <div className="ag-opts">
        {d.options.map((o) => (
          <button
            key={o.key}
            type="button"
            className="btn small"
            disabled={!d.answerable || o.free || busy !== null}
            title={o.free ? "free text: answer in the session" : undefined}
            onClick={() => void press(o.key)}
          >
            {o.key}. {o.label}
          </button>
        ))}
        {d.escape && (
          <button
            type="button"
            className="btn small"
            disabled={!d.answerable || busy !== null}
            onClick={() => void press("esc")}
          >
            Esc
          </button>
        )}
      </div>
      {!d.answerable && <p className="muted">not the default tmux server: answer in the session</p>}
      {err && (
        <p className="ag-err">
          <i className="dot bad" /> {err}
        </p>
      )}
    </div>
  );
}

function Team({ session, socket }: { session: string; socket: string }) {
  const key = `/api/agents/team?session=${encodeURIComponent(session)}&socket=${encodeURIComponent(socket)}`;
  const { data, error } = useResource<TeamData>(key, { every: 10_000 });
  if (error && !data)
    return (
      <p className="ag-err">
        <i className="dot bad" /> team: {error.message}
      </p>
    );
  if (!data) return <span className="muted">…</span>;
  const running = data.agents.filter((a) => a.state === "running").length;
  const none = !data.agents.length && !data.workflows.length && !data.tasks.length;
  return (
    <>
      {none && <p className="muted">0 subagents · 0 workflows · 0 tasks</p>}
      {data.workflows.length > 0 && (
        <>
          <p className="ag-sub">Workflows · {data.workflows.length}</p>
          <ul className="ag-list">
            {data.workflows.slice(0, 6).map((w, i) => (
              <li key={i} className={w.state === "running" ? "st-busy" : "st-idle"}>
                <i className="ag-dot" />
                <span>{w.label}</span>
                <em>
                  {w.state}
                  {w.agents != null && ` · ${w.agents} agents`}
                </em>
              </li>
            ))}
          </ul>
        </>
      )}
      {data.agents.length > 0 && (
        <>
          <p className="ag-sub">
            Subagents · {running} running / {data.agents.length}
          </p>
          <ul className="ag-list">
            {data.agents.slice(0, 12).map((a, i) => (
              <li key={i} className={a.state === "running" ? "st-busy" : "st-idle"}>
                <i className="ag-dot" />
                <span title={a.label}>{a.label.slice(0, 90)}</span>
                <em>
                  {a.type} {a.mtime ? ago(Math.floor(a.mtime)) : ""}
                </em>
              </li>
            ))}
          </ul>
          {data.agents.length > 12 && <p className="muted">+{data.agents.length - 12} more</p>}
        </>
      )}
      {data.tasks.length > 0 && (
        <>
          <p className="ag-sub">Background tasks · {data.tasks.length}</p>
          <ul className="ag-list">
            {data.tasks.slice(0, 6).map((t, i) => (
              <li key={i} className={t.state === "running" ? "st-busy" : "st-idle"}>
                <i className="ag-dot" />
                <span>{t.label.slice(0, 90)}</span>
                <em>{t.state}</em>
              </li>
            ))}
          </ul>
        </>
      )}
    </>
  );
}
