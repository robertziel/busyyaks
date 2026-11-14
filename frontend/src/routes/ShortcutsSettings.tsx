// /settings/shortcuts — Shortcuts: the key that starts / stops dictation in an open card. Record = press
// the combination; one the browser, the OS or the editor owns is refused with the reason. Kept in this browser.
// The shortcut is shown as key caps in a well; while recording the well listens (a ring) and shows the modifiers held
// so far; a refused combination shakes it, a saved one settles in.
import { Fragment, useEffect, useState } from "react";
import { useTitle } from "../lib/title";
import {
  cancelLabel,
  CHANGED,
  comboOf,
  DEFAULT_SHORTCUT,
  heldOf,
  readShortcut,
  takenHint,
  touchScreen,
  type ShortcutState,
  writeShortcut,
} from "../lib/dictationShortcut";
import { comboKeys, comboLabel, comboRefusal, isMac, type KeyCombo } from "../vendor/agents_kanban";

// one cap per key; elsewhere than on a Mac the keys are joined by "+" (the well reads "Alt+R", as the label does)
function Caps({ combo, mac }: { combo: KeyCombo; mac: boolean }) {
  return comboKeys(combo, mac).map((key, i) => (
    <Fragment key={key}>
      {i > 0 && !mac && <span className="sc-plus">+</span>}
      <span className="sc-cap">{key}</span>
    </Fragment>
  ));
}

export function ShortcutsSettings() {
  useTitle("shortcuts");
  const mac = isMac(navigator.platform);
  const [touch] = useState(touchScreen);
  const [state, setState] = useState<ShortcutState>(readShortcut);
  const [recording, setRecording] = useState(false);
  const [msg, setMsg] = useState<{ bad: boolean; text: string } | null>(null);
  const [held, setHeld] = useState<KeyCombo | null>(null); // recording: the modifiers down, the key still to come
  const [refusals, setRefusals] = useState(0); // each refused combination shakes the well again

  useEffect(() => {
    const on = () => setState(readShortcut());
    document.addEventListener(CHANGED, on);
    return () => document.removeEventListener(CHANGED, on);
  }, []);

  useEffect(() => {
    if (!recording) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.code === "Escape" && !e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey) {
        setRecording(false);
        setMsg(null);
        return;
      }
      const c = comboOf(e);
      if (!c) {
        setHeld(heldOf(e)); // a modifier on its own: wait for the key
        return;
      }
      const why = comboRefusal(c);
      if (why) {
        setMsg({ bad: true, text: `${comboLabel(c, mac)} — ${why}` });
        setRefusals((n) => n + 1);
        return;
      }
      const err = writeShortcut(c);
      setRecording(false);
      setMsg(err ? { bad: true, text: err } : { bad: false, text: `saved: ${comboLabel(c, mac)}` });
    };
    const onUp = (e: KeyboardEvent) => setHeld(heldOf(e));
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("keyup", onUp, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("keyup", onUp, true);
      setHeld(null);
    };
  }, [recording, mac]);

  const set = (v: Parameters<typeof writeShortcut>[0], ok: string) => {
    const err = writeShortcut(v);
    setMsg(err ? { bad: true, text: err } : { bad: false, text: ok });
  };

  return (
    <>
      <h1>Shortcuts</h1>
      <p className="muted as-meta">kept in this browser</p>
      <section className="card as-section shortcuts">
        <h2>Hold to dictate a comment</h2>
        <p className="muted">In an open card: hold the keys to talk into the comment box, release them to stop.</p>
        <div className="sc-row">
          <kbd
            key={refusals}
            className={`sc-key${recording ? " rec" : ""}${recording && refusals > 0 ? " refused" : ""}${msg && !msg.bad ? " saved" : ""}`}
            aria-label="Current shortcut"
          >
            {recording ? (
              held ? (
                <>
                  <Caps combo={held} mac={mac} />
                  <span className="sc-hint">…</span>
                </>
              ) : (
                <span className="sc-hint">press keys…</span>
              )
            ) : state.combo ? (
              <Caps combo={state.combo} mac={mac} />
            ) : (
              <span className="sc-hint">none</span>
            )}
          </kbd>
          <button
            type="button"
            className={`btn${recording ? " primary" : ""}`}
            aria-pressed={recording}
            onClick={() => {
              setMsg(null);
              setRefusals(0);
              setRecording((r) => !r);
            }}
          >
            {recording ? cancelLabel(touch) : "Record"}
          </button>
          <button
            type="button"
            className="btn"
            disabled={recording || (!state.stored && !state.error)}
            onClick={() => set("default", `reset: ${comboLabel(DEFAULT_SHORTCUT, mac)}`)}
          >
            Reset to {comboLabel(DEFAULT_SHORTCUT, mac)}
          </button>
          <button
            type="button"
            className="btn"
            disabled={recording || (state.stored && state.combo === null && !state.error)}
            onClick={() => set(null, "no shortcut: the mic button only")}
          >
            None
          </button>
        </div>
        {state.error && (
          <div className="flash bad" role="alert">
            <i className="dot bad" />
            {state.error} — record a new one or reset
          </div>
        )}
        {msg && (
          <p className={`sc-msg ${msg.bad ? "err" : "ok"}`} role={msg.bad ? "alert" : "status"}>
            {msg.text}
          </p>
        )}
        {recording && held && (
          // shown only when the key still has not come after a moment (CSS delay): a combination another app on this
          // computer takes (a global hotkey) never reaches the browser — only its modifiers do
          <p className="sc-msg sc-taken muted" role="status">
            {takenHint(held, mac)}
          </p>
        )}
      </section>
    </>
  );
}
