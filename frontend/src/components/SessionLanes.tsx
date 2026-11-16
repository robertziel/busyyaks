// The project page's session lanes, pure over its props (Sessions.tsx holds the state; the tests render this to markup).
// See Sessions.tsx for what each lane shows and how a chip opens its terminal.
import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Link } from "react-router-dom";
import { ApiError, apiPost, invalidate } from "../api";
import { ago, at } from "../lib/format";
import {
  chipCard,
  elapsedText,
  NEED_WORD,
  needOf,
  nextChip,
  phaseParts,
  phaseWord,
  quietShown,
  quietWord,
  QUIET_LIMIT,
  type ChipEvent,
  type ChipState,
  type LaneSession,
  type Lanes,
  type LiveIssue,
  menuPosition,
  type MenuPos,
  heldCard,
  registered,
  regText,
  triggerHidden,
} from "../lib/sessionLanes";
import type { AgentSession } from "../types";
import { AgentFace, moodOf } from "../vendor/agents_kanban";

export type ViewProps = {
  lanes: Lanes;
  chip: ChipState;
  dispatch: (e: ChipEvent) => void;
  quietOpen: boolean;
  onQuietOpen: (v: boolean) => void;
  busy: string | null;
  stop: (names: string[], what: string) => void;
  launch: ReactNode;
  issue: LiveIssue; // the Agents read is missing or old (liveIssue): said above the lanes; old = dimmed, nothing answerable
};

export function SessionLanesView({
  lanes,
  chip,
  dispatch,
  quietOpen,
  onQuietOpen,
  busy,
  stop,
  launch,
  issue,
}: ViewProps) {
  const all = [...lanes.you, ...lanes.working, ...lanes.quiet];
  const quiet = quietShown(lanes.quiet, quietOpen, chip.selected);
  const order = [...lanes.you, ...lanes.working, ...quiet.shown].map((l) => l.tmux.name);
  const root = useRef<HTMLDivElement>(null);
  const onKey = (name: string) => (e: KeyboardEvent<HTMLButtonElement>) => {
    const to = nextChip(order, name, e.key);
    if (!to) {
      if (e.key === "Escape") dispatch({ type: "dismiss" });
      return;
    }
    e.preventDefault();
    e.stopPropagation(); // the board's own arrow keys (document listener) move its card focus: not from a chip
    root.current?.querySelector<HTMLButtonElement>(`[data-chip="${CSS.escape(to)}"]`)?.focus();
  };
  const sel = all.find((l) => l.tmux.name === chip.selected) ?? null;
  const old = issue?.kind === "old"; // the last snapshot: shown, never answered
  const chipProps = (l: LaneSession) => ({ l, chip, dispatch, onKey: onKey(l.tmux.name), busy, stop, old });
  const strip = (lane: LaneSession["lane"]) =>
    sel && sel.lane === lane ? <DetailStrip l={sel} dispatch={dispatch} /> : null;
  return (
    <div className={`lanes${old ? " stale" : ""}`} ref={root} aria-label="Agent sessions" tabIndex={-1}>
      {issue && (
        <p className="lanes-err" role="alert">
          <i className="dot bad" /> {issue.text}
        </p>
      )}
      {lanes.you.length > 0 && (
        <section className="lane you" aria-labelledby="lane-you">
          <h3 className="lane-label" id="lane-you">
            Needs you <span>{lanes.you.length}</span>
          </h3>
          <div className="lane-body">
            {lanes.you.map((l) => (
              <NeedCard key={l.tmux.name} {...chipProps(l)} />
            ))}
            {strip("you")}
          </div>
        </section>
      )}
      {lanes.working.length > 0 && (
        <section className="lane" aria-labelledby="lane-working">
          <h3 className="lane-label" id="lane-working">
            Working <span>{lanes.working.length}</span>
          </h3>
          <div className="lane-body">
            {lanes.working.map((l) => (
              <WorkChip key={l.tmux.name} {...chipProps(l)} />
            ))}
            {strip("working")}
          </div>
        </section>
      )}
      <section className="lane quiet" aria-labelledby="lane-quiet">
        <h3 className="lane-label" id="lane-quiet">
          Quiet <span>{lanes.quiet.length}</span>
        </h3>
        <div className="lane-body">
          {quiet.shown.map((l) => (
            <QuietPill key={l.tmux.name} {...chipProps(l)} />
          ))}
          {lanes.quiet.length > QUIET_LIMIT && (
            <button
              type="button"
              className="lane-more"
              aria-expanded={quietOpen}
              onClick={() => onQuietOpen(!quietOpen)}
              title={quietOpen ? "Fold the quiet sessions" : `Show ${quiet.hidden} more quiet sessions`}
            >
              {quietOpen ? "fewer" : `+${quiet.hidden} quiet`}
            </button>
          )}
          {lanes.quiet.length === 0 && all.length === 0 && <span className="muted lane-none">no sessions</span>}
          <span className="lane-launch">
            {launch}
            <SectionMenu names={all.map((l) => l.tmux.name)} busy={busy} stop={stop} />
          </span>
          {strip("quiet")}
        </div>
      </section>
    </div>
  );
}

type ChipProps = {
  old: boolean; // the lanes show the last snapshot: the answer buttons are off
  l: LaneSession;
  chip: ChipState;
  dispatch: (e: ChipEvent) => void;
  onKey: (e: KeyboardEvent<HTMLButtonElement>) => void;
  busy: string | null;
  stop: (names: string[], what: string) => void;
};

function Face({ l, size }: { l: LaneSession; size: number }) {
  const a = l.agent;
  return (
    <span
      className={`lane-face${l.tmux.attached ? " attached" : ""}${a?.unread ? " unread" : ""}`}
      title={`${l.tmux.attached ? "attached" : "detached"}${a?.unread ? " · unread: its turn ended since you last looked" : ""}`}
    >
      <AgentFace
        // one source: the session's registration (unread or none → its tmux name and the neutral "unknown" type)
        name={registered(l.reg)?.agent ?? l.tmux.name}
        type={registered(l.reg)?.type ?? null}
        mood={a ? moodOf({ state: a.state, phase: a.phase }) : null}
        size={size}
      />
    </span>
  );
}

// the chip's main button: the primary action (the terminal); the pointer type decides a touch tap (strip only)
function MainButton({
  l,
  chip,
  dispatch,
  onKey,
  label,
  children,
}: Omit<ChipProps, "busy" | "stop" | "old"> & { label: string; children: ReactNode }) {
  const pointer = useRef<"mouse" | "touch" | "pen" | "key">("key");
  const canOpen = l.agent !== null;
  return (
    <button
      type="button"
      className="lane-main"
      data-chip={l.tmux.name}
      aria-label={label}
      aria-describedby={chip.selected === l.tmux.name ? "lane-strip" : undefined}
      aria-disabled={canOpen ? undefined : true}
      onPointerDown={(e) =>
        (pointer.current = e.pointerType === "touch" || e.pointerType === "pen" ? e.pointerType : "mouse")
      }
      onKeyDown={(e) => {
        pointer.current = "key";
        onKey(e);
      }}
      onFocus={(e) => {
        // keyboard focus only (focus-visible): a mouse click focuses the button too, and must move no strip in
        if (e.currentTarget.matches(":focus-visible")) dispatch({ type: "focus", name: l.tmux.name });
      }}
      onClick={() => {
        // no live state = no socket to attach to: the strip says why, nothing is opened on a guessed server
        if (!canOpen) dispatch({ type: "activate", name: l.tmux.name, pointer: "touch" });
        else dispatch({ type: "activate", name: l.tmux.name, pointer: pointer.current });
        pointer.current = "key";
      }}
    >
      {children}
    </button>
  );
}

function CardRef({ a }: { a: AgentSession | null }) {
  const c = chipCard(a);
  if (!c) return null;
  const body = (
    <>
      <b className="mono">#{c.id}</b>
      {c.title && <span>{c.title}</span>}
    </>
  );
  return c.path ? (
    <Link className="lane-card" to={c.path} data-card-id={c.id} title={`card ${c.id}${c.title ? `: ${c.title}` : ""}`}>
      {body}
    </Link>
  ) : (
    <span className="lane-card" data-card-id={c.id}>
      {body}
    </span>
  );
}

function NeedCard({ l, chip, dispatch, onKey, busy, stop, old }: ChipProps) {
  const a = l.agent!; // the Needs-you lane holds only sessions with a live state
  const need = needOf(a);
  return (
    <div className={`lane-need${chip.selected === l.tmux.name ? " on" : ""}`}>
      <div className="need-head">
        <MainButton
          l={l}
          chip={chip}
          dispatch={dispatch}
          onKey={onKey}
          label={`${l.tmux.name}: needs you — ${NEED_WORD[need.kind]}. Open terminal`}
        >
          <Face l={l} size={22} />
          <span className="lane-name mono" title={l.tmux.name}>
            {l.short}
          </span>
          <span className="lane-st you">
            <i aria-hidden="true" />
            {NEED_WORD[need.kind]}
          </span>
        </MainButton>
        <span className="spacer" />
        <SessionMenu l={l} busy={busy} stop={stop} />
      </div>
      <Answer a={a} need={need} old={old} />
    </div>
  );
}

const STALE = "the live read is old: answer once it refreshes (or on the card / in the session)";

// the question / dialog / review and its answer buttons — each its own target (a click answers, nothing else)
function Answer({ a, need, old }: { a: AgentSession; need: ReturnType<typeof needOf>; old: boolean }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const run = async (key: string, call: () => Promise<unknown>) => {
    setBusy(key);
    setErr(null);
    try {
      await call();
      invalidate("/api/agents");
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };
  const press = (key: string) =>
    need.kind === "dialog"
      ? run(key, () =>
          apiPost("/api/agents/answer", { session: a.name, socket: a.socket, hash: need.dialog.hash, key }),
        )
      : Promise.resolve();
  const post = (cardId: number, option: string) =>
    run(option, () => apiPost(`/api/cards/${cardId}/comment`, { body: option }));
  return (
    <>
      {need.kind === "dialog" && (
        <p className="need-q">
          {need.question}
          {need.command && <code>{need.command}</code>}
        </p>
      )}
      {need.kind === "question" && <p className="need-q">{need.question}</p>}
      {need.kind === "review" && <p className="need-q">PR to review: {need.card.title}</p>}
      {need.kind === "waiting" && <p className="need-q">waiting: {need.text}</p>}
      <div className="need-foot">
        {need.kind === "question" || need.kind === "review" ? (
          <Link className="lane-card" to={need.card.path} data-card-id={need.card.id}>
            <b className="mono">#{need.card.id}</b>
            <span>{need.card.title}</span>
          </Link>
        ) : (
          <CardRef a={a} />
        )}
        <span className="spacer" />
        {need.kind === "dialog" && (
          <span className="need-opts" role="group" aria-label={`Answer ${a.name}'s dialog`}>
            {need.dialog.options.map((o, i) => (
              <button
                key={o.key}
                type="button"
                className={`btn small${i === 0 ? " need-pri" : ""}`}
                disabled={old || !need.dialog.answerable || o.free || busy !== null}
                title={old ? STALE : o.free ? "free text: answer in the session" : `Press ${o.key} in ${a.name}`}
                onClick={() => void press(o.key)}
              >
                {o.key}. {o.label}
              </button>
            ))}
            {need.dialog.escape && (
              <button
                type="button"
                className="btn small"
                disabled={old || !need.dialog.answerable || busy !== null}
                title={old ? STALE : `Press Esc in ${a.name}`}
                onClick={() => void press("esc")}
              >
                Esc
              </button>
            )}
          </span>
        )}
        {need.kind === "question" && need.card.options.length > 0 && (
          <span className="need-opts" role="group" aria-label={`Answer card ${need.card.id}`}>
            {need.card.options.map((o, i) => (
              <button
                key={o}
                type="button"
                className={`btn small${i === 0 ? " need-pri" : ""}`}
                disabled={old || busy !== null}
                title={old ? STALE : "Post this as your answer on the card"}
                onClick={() => void post(need.card.id, o)}
              >
                {o}
              </button>
            ))}
          </span>
        )}
        {need.kind === "review" && need.card.pr_url && (
          <a className="btn small" href={need.card.pr_url} target="_blank" rel="noreferrer">
            PR ↗
          </a>
        )}
      </div>
      {need.kind === "dialog" && !need.dialog.answerable && (
        <p className="muted need-note">not the default tmux server: answer in the session</p>
      )}
      {err && (
        <p className="lanes-err" role="alert">
          <i className="dot bad" /> {err}
        </p>
      )}
    </>
  );
}

function WorkChip({ l, chip, dispatch, onKey, old, busy, stop }: ChipProps) {
  const a = l.agent!;
  const phase = phaseWord(a);
  const parts = phaseParts(a);
  const el = elapsedText(a.live.elapsed_s);
  return (
    <div className={`lane-work${chip.selected === l.tmux.name ? " on" : ""}`}>
      <span className="lane-work-head">
        <MainButton
          l={l}
          chip={chip}
          dispatch={dispatch}
          onKey={onKey}
          label={`${l.tmux.name}: ${phase}${old ? " (last snapshot)" : ""}. Open terminal`}
        >
          <Face l={l} size={22} />
          <span className="lane-name mono" title={l.tmux.name}>
            {l.short}
          </span>
          <span className="lane-st live" title={phase}>
            <i aria-hidden="true" />
            <span className="lane-st-w">{parts.word}</span>
            {parts.tool && <span className="lane-st-tool">· {parts.tool}</span>}
          </span>
        </MainButton>
        <SessionMenu l={l} busy={busy} stop={stop} />
      </span>
      <span className="lane-sub">
        <CardRef a={a} />
        {el && (
          <span className="lane-el mono" title="the turn's elapsed time, as its status line shows it">
            {el}
          </span>
        )}
      </span>
    </div>
  );
}

function QuietPill({ l, chip, dispatch, onKey, busy, stop }: ChipProps) {
  const w = l.liveRead ? quietWord(l.agent) : { word: "live state unknown", tone: "unknown" as const };
  const c = heldCard(l.agent);
  return (
    <div className={`lane-quiet${chip.selected === l.tmux.name ? " on" : ""}`}>
      <MainButton
        l={l}
        chip={chip}
        dispatch={dispatch}
        onKey={onKey}
        label={`${l.tmux.name}: ${w.word}. Open terminal`}
      >
        <Face l={l} size={18} />
        <span className="lane-name mono" title={l.tmux.name}>
          {l.short}
        </span>
        <span className={`lane-st ${w.tone}`}>
          <i aria-hidden="true" />
          {w.word}
        </span>
      </MainButton>
      {c &&
        w.tone === "ci" &&
        (c.path ? (
          <Link className="lane-cid mono" to={c.path} data-card-id={c.id}>
            #{c.id}
          </Link>
        ) : null)}
      <SessionMenu l={l} busy={busy} stop={stop} />
    </div>
  );
}

// the selected chip's details + the explicit "Open terminal" (the touch path); its menu is on the chip itself
// (a strip that closes on mouseleave can hold nothing the pointer must travel to; no hover opens it at all)
function DetailStrip({ l, dispatch }: { l: LaneSession; dispatch: (e: ChipEvent) => void }) {
  const a = l.agent;
  const el = a ? elapsedText(a.live.elapsed_s) : null;
  return (
    <div className="lane-strip" id="lane-strip">
      <span className="mono muted" title={`started ${at(l.tmux.created)}`}>
        {l.tmux.name}
        {regText(l.reg)} · {ago(l.tmux.created)}
      </span>
      {a ? (
        <>
          {a.live.tool && <span className="mono lane-det">{a.live.tool}</span>}
          {(el || a.live.tokens) && (
            <span className="mono muted">{[el, a.live.tokens].filter(Boolean).join(" · ")}</span>
          )}
          {a.state_by && <span className="muted lane-by">{a.state_by}</span>}
        </>
      ) : (
        <span className="muted">
          {l.liveRead
            ? "no live state: the Agents read does not list this session — no terminal to attach"
            : "live state unknown: the Agents read has not answered — no terminal to attach"}
        </span>
      )}
      <span className="spacer" />
      {a && (
        <button
          type="button"
          className="btn small"
          onClick={() => dispatch({ type: "openTerminal", name: l.tmux.name })}
        >
          Open terminal
        </button>
      )}
    </div>
  );
}

// ── the ⋯ menus ─────────────────────────────────────────────────────────────────────────────────────────────────────
export type Item = {
  label: string;
  icon: string;
  danger?: boolean;
  href?: string;
  copy?: string;
  run?: () => void;
  off?: string;
};

function Menu({ label, head, items }: { label: string; head?: string; items: Item[] }) {
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const btn = useRef<HTMLButtonElement>(null);
  const list = useRef<HTMLDivElement>(null);
  // the menu is a portal into <body>, fixed at its trigger (menuPosition) — inside the lanes' card (its
  // backdrop-filter = a stacking context) the board painted over it. Placed again on every scroll / resize.
  const [at, setAt] = useState<MenuPos | null>(null);
  useLayoutEffect(() => {
    if (!open) return setAt(null);
    const place = () => {
      const b = btn.current?.getBoundingClientRect();
      const pop = list.current?.getBoundingClientRect();
      // its trigger scrolled out of sight (under the sticky header / title, or off the window): the menu closes, never
      // following it over the header
      // the sticky header and the project page's sticky title below it: whatever stays pinned at the top
      const header = Math.max(
        0,
        ...[...document.querySelectorAll(".top, h1.proj-title")].map((e) => e.getBoundingClientRect().bottom),
      );
      if (b && triggerHidden(b, header, window.innerHeight)) return setOpen(false);
      if (b && pop)
        setAt(
          menuPosition(
            b,
            { width: pop.width, height: pop.height },
            { width: window.innerWidth, height: window.innerHeight },
          ),
        );
    };
    place();
    window.addEventListener("scroll", place, true);
    window.addEventListener("resize", place);
    return () => {
      window.removeEventListener("scroll", place, true);
      window.removeEventListener("resize", place);
    };
  }, [open]);
  // the first item takes focus once the menu is placed (hidden while measured: a hidden element takes no focus)
  const placed = at !== null;
  useEffect(() => {
    if (open && placed)
      list.current?.querySelector<HTMLElement>("[role=menuitem]:not([aria-disabled])")?.focus({ preventScroll: true });
  }, [open, placed]);
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => {
      if (!list.current?.contains(e.target as Node) && !btn.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", away);
    return () => document.removeEventListener("pointerdown", away);
  }, [open]);
  const close = () => {
    setOpen(false);
    btn.current?.focus();
  };
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    e.stopPropagation(); // the menu's keys are its own: the board's document-level arrows never see them
    const els = Array.from(list.current?.querySelectorAll<HTMLElement>("[role=menuitem]") ?? []);
    const i = els.indexOf(document.activeElement as HTMLElement);
    if (e.key === "Escape") {
      e.preventDefault();
      close();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const d = e.key === "ArrowDown" ? 1 : -1;
      els[(i + d + els.length) % els.length]?.focus();
    } else if (e.key === "Home" || e.key === "End") {
      e.preventDefault();
      (e.key === "Home" ? els[0] : els.at(-1))?.focus();
    } else if (e.key === "Tab") {
      // the menu lives at the end of <body>: Tab would leave the page — close it and go on from its button
      e.preventDefault();
      close();
    }
  };
  const pick = (it: Item) => {
    if (it.off) return;
    if (it.copy !== undefined) {
      const text = it.copy;
      if (!navigator.clipboard) setNote("copy refused: no clipboard here");
      else
        navigator.clipboard.writeText(text).then(
          () => setNote("copied ✓"),
          () => setNote("copy refused"),
        );
      return;
    }
    it.run?.();
    close();
  };
  return (
    <span className="lane-menu">
      <button
        ref={btn}
        type="button"
        className="lane-kebab"
        aria-label={label}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => {
          setNote(null);
          setOpen(!open);
        }}
      >
        ⋯
      </button>
      {open &&
        createPortal(
          <div
            className={`lane-pop${at?.up ? " up" : ""}`}
            role="menu"
            aria-label={label}
            ref={list}
            onKeyDown={onKey}
            // measured hidden on the first frame, then placed (never drawn at a guessed spot)
            style={at ? { top: at.top, left: at.left } : { top: 0, left: 0, visibility: "hidden" }}
          >
            {head && <div className="lane-pop-head mono">{head}</div>}
            {items.map((it) =>
              it.href && !it.off ? (
                <a
                  key={it.label}
                  role="menuitem"
                  tabIndex={-1}
                  className="lane-mi"
                  href={it.href}
                  target="_blank"
                  rel="noopener"
                  onClick={() => setOpen(false)}
                >
                  <span className="ic" aria-hidden="true">
                    {it.icon}
                  </span>
                  {it.label}
                </a>
              ) : (
                <button
                  key={it.label}
                  type="button"
                  role="menuitem"
                  tabIndex={-1}
                  className={`lane-mi${it.danger ? " bad" : ""}`}
                  aria-disabled={it.off ? true : undefined}
                  title={it.off}
                  onClick={() => pick(it)}
                >
                  <span className="ic" aria-hidden="true">
                    {it.icon}
                  </span>
                  {it.label}
                </button>
              ),
            )}
            {note && (
              <div className="lane-pop-note" role="status">
                {note}
              </div>
            )}
          </div>,
          document.body,
        )}
    </span>
  );
}

// a session's ⋯ entries — the same list on every chip, pill and answer card (exported: the tests read it)
export function sessionMenuItems(l: LaneSession, busy: string | null, stop: (n: string[], w: string) => void): Item[] {
  const s = l.tmux;
  return [
    {
      label: "Open in Claude app",
      icon: "↗",
      href: s.claude_url ?? undefined,
      off: s.claude_url ? undefined : "no Remote Control session (not started with --remote-control, or Hermes)",
    },
    { label: "Copy iTerm attach", icon: "⧉", copy: s.ssh_attach },
    { label: "Open external terminal", icon: "↗", href: s.terminal_url },
    { label: "Copy tmux attach", icon: "⧉", copy: `tmux attach -t ${s.name}` },
    {
      label: busy === s.name ? "Stopping…" : "Stop session",
      icon: "■",
      danger: true,
      off: busy !== null ? "a stop is running" : undefined,
      run: () => stop([s.name], s.name),
    },
  ];
}

function SessionMenu({
  l,
  busy,
  stop,
}: {
  l: LaneSession;
  busy: string | null;
  stop: (n: string[], w: string) => void;
}) {
  const s = l.tmux;
  return (
    <Menu
      label={`${s.name} actions`}
      head={`${s.name}${regText(l.reg)} · ${ago(s.created)}`}
      items={sessionMenuItems(l, busy, stop)}
    />
  );
}

function SectionMenu({
  names,
  busy,
  stop,
}: {
  names: string[];
  busy: string | null;
  stop: (n: string[], w: string) => void;
}) {
  if (names.length < 2) return null;
  return (
    <Menu
      label="All sessions actions"
      items={[
        {
          label: busy === "*" ? "Stopping…" : `Stop all (${names.length})`,
          icon: "■",
          danger: true,
          off: busy !== null ? "a stop is running" : undefined,
          run: () => stop(names, "*"),
        },
      ]}
    />
  );
}
