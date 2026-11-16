// An agent session's live terminal: its tmux pane over /api/terminal (lib/terminalStream.ts), drawn by
// xterm.js at the pane's own size — the browser never resizes the agent's window. Read-only until Take control: the
// launcher confirms each change, keys typed while not in control never leave the page (and the server refuses them
// too). Opening it, taking and releasing control are logged on the session's cards by the server.
// It is drawn as a terminal window (styles/terminal.css): a title bar (close · full window, the session, the one
// action), the screen, a status bar (state · what went wrong · the pane's size); in control the frame turns amber.
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
} from "react";
import { createPortal } from "react-dom";
import { Terminal } from "@xterm/xterm";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import { controlFrame, inputFrame, parseServer, REFUSED_BEFORE_OPEN, terminalUrl } from "../lib/terminalStream";
import { fitFontSize, TERMINAL_CHROME, TERMINAL_THEME } from "../lib/terminalTheme";

type Status = "connecting" | "open" | "ended" | "failed";

// the font follows the room: the largest size at which the pane's columns fit (the full window: its rows too), within
// these; a pane too big for MIN_FONT scrolls — the agent's window is never resized
const MIN_FONT = 10;
const MAX_FONT = 14;
const MAX_FONT_FULL = 16;
const px = (v: string) => parseFloat(v);

// the page's monospace stack (app.css --mono); none = the stylesheet is missing: fail, never another font
function monoFont(): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue("--mono").trim();
  if (!v) throw new Error("the --mono token is not defined (public/static/app.css): the terminal has no font");
  return v;
}

// overlay = always over the whole page (the Agents sidebar: too narrow for a pane). The full window is a portal: into
// the open <dialog> the terminal sits in (the card dialog is modal — the top layer: anything outside it is inert, under
// its backdrop), else into <body> — an ancestor with backdrop-filter / transform (the sidebar) would otherwise be the
// containing block of a position:fixed child and clip it. xterm draws into one element made here, moved between the
// inline slot and the overlay — the terminal and its socket survive the switch. Esc inside the terminal is the
// agent's key: it never closes the dialog around it.
export function LiveTerminal({
  session,
  socket,
  onClose,
  overlay = false,
}: {
  session: string;
  socket: string;
  onClose?: () => void;
  overlay?: boolean;
}) {
  const [screen] = useState(() => {
    const d = document.createElement("div");
    d.className = "lt-screen";
    return d;
  });
  // where the full window goes: the open <dialog> around this terminal's place, else <body> — read each time the full
  // window turns on (a dialog shown in the same commit as this terminal is open only after its own effect)
  const anchor = useRef<HTMLSpanElement>(null);
  const [host, setHost] = useState<HTMLElement | null>(null);
  // the room changed (the page, the dialog, inline ↔ full window) → the font is fitted again
  const refit = useRef<() => void>(() => undefined);
  const [room] = useState(() => new ResizeObserver(() => refit.current()));
  useEffect(() => () => room.disconnect(), [room]);
  const slot = useCallback(
    (node: HTMLDivElement | null) => {
      if (!node) return;
      node.appendChild(screen);
      const root = node.closest(".lt");
      if (!root) throw new Error("the terminal's slot is outside its .lt root");
      room.disconnect();
      room.observe(root);
    },
    [screen, room],
  );
  const ws = useRef<WebSocket | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [status, setStatus] = useState<Status>("connecting");
  const [control, setControl] = useState(false);
  const [asked, setAsked] = useState(false); // a control change sent, the launcher's answer not back yet
  const [note, setNote] = useState<string | null>(null);
  const [size, setSize] = useState<{ cols: number; rows: number } | null>(null); // the pane's, once the server said
  const [fullState, setFull] = useState(false);
  const full = overlay || fullState;
  useLayoutEffect(() => {
    if (full) setHost((anchor.current?.closest("dialog[open]") as HTMLElement | null) ?? document.body);
  }, [full]);

  useEffect(() => {
    const el = screen;
    const term = new Terminal({
      cols: 80,
      rows: 24,
      fontSize: MAX_FONT,
      lineHeight: 1, // the font's own line: a taller row breaks the box-drawing lines agents draw (│ ╭ ╰)
      fontFamily: monoFont(),
      theme: TERMINAL_THEME,
      minimumContrastRatio: 4.5,
      scrollback: 2000,
      disableStdin: true,
      cursorBlink: false,
      cursorStyle: "block",
      cursorInactiveStyle: "outline",
    });
    term.loadAddon(new WebLinksAddon());
    term.open(el);
    let fontSize = MAX_FONT;
    const fit = () => {
      const root = el.closest<HTMLElement>(".lt");
      const win = el.closest<HTMLElement>(".lt-win");
      const bar = win?.querySelector<HTMLElement>(".lt-bar");
      const foot = win?.querySelector<HTMLElement>(".lt-foot");
      const drawn = el.querySelector<HTMLElement>(".xterm-screen");
      if (!root || !win || !bar || !foot || !drawn || drawn.offsetWidth === 0) return; // not in the page yet
      const [rs, ws, ss] = [getComputedStyle(root), getComputedStyle(win), getComputedStyle(el)];
      const width =
        root.clientWidth -
        (px(rs.paddingLeft) + px(rs.paddingRight)) -
        (px(ws.borderLeftWidth) + px(ws.borderRightWidth)) -
        (px(ss.paddingLeft) + px(ss.paddingRight)) -
        (el.offsetWidth - el.clientWidth);
      const isFull = root.classList.contains("lt-full");
      const height = isFull
        ? root.clientHeight -
          (px(rs.paddingTop) + px(rs.paddingBottom)) -
          (px(ws.borderTopWidth) + px(ws.borderBottomWidth)) -
          (px(ss.paddingTop) + px(ss.paddingBottom)) -
          bar.offsetHeight -
          foot.offsetHeight
        : null;
      const cell = { w: drawn.offsetWidth / term.cols / fontSize, h: drawn.offsetHeight / term.rows / fontSize };
      const max = isFull ? MAX_FONT_FULL : MAX_FONT;
      let next = fitFontSize({ cols: term.cols, rows: term.rows, cell, width, height, min: MIN_FONT, max });
      const apply = (n: number) => {
        if (n === fontSize) return;
        fontSize = n;
        term.options.fontSize = n;
      };
      apply(next);
      // a cell is a whole number of device pixels, so the size asked for can come out a little wider: step down
      while (next > MIN_FONT && (drawn.offsetWidth > width || (height !== null && drawn.offsetHeight > height))) {
        next -= 0.5;
        apply(next);
      }
    };
    // more of the pane to the right of what shows → the screen fades at that edge (styles/terminal.css)
    const edge = () => {
      el.dataset.more = el.scrollLeft + el.clientWidth < el.scrollWidth - 1 ? "right" : "none";
    };
    refit.current = () => {
      fit();
      edge();
    };
    refit.current();
    el.addEventListener("scroll", edge, { passive: true });
    let inControl = false;
    let hello = false;
    setStatus("connecting");
    setControl(false);
    setAsked(false);
    setNote(null);
    setSize(null);

    const sock = new WebSocket(terminalUrl(window.location, session, socket));
    ws.current = sock;
    sock.onmessage = (ev: MessageEvent<unknown>) => {
      const f = parseServer(typeof ev.data === "string" ? ev.data : "");
      switch (f.kind) {
        case "hello":
          hello = true;
          term.resize(f.cols, f.rows);
          term.reset();
          term.write(f.screen);
          setSize({ cols: f.cols, rows: f.rows });
          setStatus("open");
          refit.current();
          break;
        case "output":
          term.write(f.data);
          break;
        case "size":
          term.resize(f.cols, f.rows);
          setSize({ cols: f.cols, rows: f.rows });
          refit.current();
          break;
        case "control":
          inControl = f.on;
          term.options.disableStdin = !f.on;
          term.options.cursorBlink = f.on;
          setControl(f.on);
          setAsked(false);
          if (f.on) term.focus();
          break;
        case "refused":
          setAsked(false);
          setNote(f.why);
          break;
        case "exit":
          setNote(f.why);
          setStatus("ended");
          break;
        case "denied":
          setNote(f.error);
          setStatus("failed");
          break;
        case "unknown":
          setNote(`unexpected message from the server: ${f.raw.slice(0, 120)}`);
          break;
      }
    };
    sock.onclose = (ev) => {
      inControl = false;
      term.options.disableStdin = true;
      term.options.cursorBlink = false;
      setControl(false);
      setAsked(false);
      if (!hello) {
        setNote(`${REFUSED_BEFORE_OPEN} (close ${ev.code})`);
        setStatus("failed");
      } else {
        setStatus((s) => (s === "failed" ? s : "ended"));
        if (ev.reason) setNote((n) => n ?? ev.reason);
      }
    };
    const typed = term.onData((keys) => {
      if (inControl && sock.readyState === WebSocket.OPEN) sock.send(inputFrame(keys));
    });
    return () => {
      refit.current = () => undefined;
      el.removeEventListener("scroll", edge);
      typed.dispose();
      sock.onmessage = null;
      sock.onclose = null;
      sock.close(1000, "closed in the page");
      ws.current = null;
      term.dispose();
    };
  }, [session, socket, attempt, screen]);

  const toggleControl = () => {
    const s = ws.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;
    setAsked(true);
    setNote(null);
    s.send(controlFrame(!control));
  };

  // Esc in the terminal: xterm has already handled it (typed to the agent in control); the dialog's cancel must not run
  const keepEsc = (e: KeyboardEvent) => {
    if (e.key !== "Escape") return;
    e.preventDefault();
    e.stopPropagation();
  };

  const state =
    status === "open" ? (control ? "in control" : "read-only") : status === "connecting" ? "connecting…" : status;
  const body = (
    <div
      className={`lt${full ? " lt-full" : ""}${control ? " lt-control" : ""}`}
      data-status={status}
      style={TERMINAL_CHROME as CSSProperties}
      onKeyDown={keepEsc}
    >
      <div className="lt-win">
        <div className="lt-bar">
          <span className="lt-lights">
            {onClose && (
              <button
                type="button"
                className="lt-light lt-light-close"
                aria-label="Close"
                title="Close"
                onClick={onClose}
              >
                <svg viewBox="0 0 10 10" aria-hidden="true">
                  <path d="M2.6 2.6l4.8 4.8M7.4 2.6L2.6 7.4" />
                </svg>
              </button>
            )}
            {!overlay && (
              <button
                type="button"
                className="lt-light lt-light-full"
                aria-label={full ? "Exit full window" : "Full window"}
                title={full ? "Exit full window" : "Full window"}
                aria-pressed={full}
                onClick={() => setFull((f) => !f)}
              >
                <svg viewBox="0 0 10 10" aria-hidden="true">
                  {full ? <path d="M1.8 6h2.2v2.2M8.2 4H6V1.8" /> : <path d="M5.6 2.2h2.2v2.2M4.4 7.8H2.2V5.6" />}
                </svg>
              </button>
            )}
          </span>
          <b className="lt-name" title={session}>
            {session}
          </b>
          <span className="lt-actions">
            {status === "open" && (
              <button
                type="button"
                className={`lt-btn${control ? " lt-btn-on" : ""}`}
                aria-pressed={control}
                disabled={asked}
                onClick={toggleControl}
              >
                {asked ? "…" : control ? "Release control" : "Take control"}
              </button>
            )}
            {(status === "ended" || status === "failed") && (
              <button type="button" className="lt-btn" onClick={() => setAttempt((n) => n + 1)}>
                Reconnect
              </button>
            )}
          </span>
        </div>
        <div className="lt-body">
          <div className="lt-slot" ref={slot} />
          {status === "connecting" && <p className="lt-veil">connecting to {session}…</p>}
          {status === "failed" && (
            <p className="lt-veil" role="status">
              {note}
            </p>
          )}
        </div>
        <div className="lt-foot">
          <span className={`lt-state st-${status}`}>
            <i className="lt-dot" />
            {state}
          </span>
          {control && <span className="lt-hint">your keys reach the agent</span>}
          {note && status !== "failed" && (
            <span className="lt-msg" role="status">
              {note}
            </span>
          )}
          {size && (
            <span className="lt-size">
              {size.cols}×{size.rows}
            </span>
          )}
        </div>
      </div>
    </div>
  );
  return (
    <>
      <span ref={anchor} hidden />
      {full ? host && createPortal(body, host) : body}
    </>
  );
}
