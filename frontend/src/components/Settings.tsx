// The settings cog at the right end of the header: a menu with the signed-in account, Agents & launchers (/settings),
// Agent rules (/settings/agent-rules: busyyaks's own skills layers, every global markdown a launched session gets),
// Daily report (/settings/daily-report), Runtime (/settings/runtime), Git hosts (/settings/git-hosts), Shortcuts (/settings/shortcuts),
// Updates (/settings/updates; card 536: a dot on the cog + the link's tag while an update is available),
// the hello screen (/hello),
// the skin and Sign out.
// Closes on Escape (focus back on the cog), an outside pointer, focus moving out of it (Tab) or a route change.
import { useEffect, useId, useRef, useState, type RefObject } from "react";
import { Link, useLocation } from "react-router-dom";
import { csrfToken, signOutPath, useResource, userEmail } from "../api";
import { notice, type UpdateStatus } from "../lib/updates";
import { SkinSwitch } from "./Skin";

export function Settings() {
  const email = userEmail();
  const signOut = signOutPath();
  const location = useLocation();
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const btn = useRef<HTMLButtonElement>(null);
  // the launcher answers from its last check (and re-checks on its own past updates.check_minutes); a failed read →
  // no notice, Settings → Updates says why
  const updates = useResource<UpdateStatus>("/api/settings/update", {
    every: 600_000,
  });

  useEffect(() => setOpen(false), [location.pathname]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      setOpen(false);
      btn.current?.focus({ preventScroll: true });
    };
    const outside = (e: Event) => {
      if (!wrap.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", outside);
    document.addEventListener("focusin", outside);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", outside);
      document.removeEventListener("focusin", outside);
    };
  }, [open]);

  return (
    <SettingsView
      open={open}
      onToggle={() => setOpen((o) => !o)}
      email={email}
      signOut={signOut}
      csrf={signOut ? csrfToken() : ""}
      update={notice(updates.data)}
      wrap={wrap}
      btn={btn}
    />
  );
}

type ViewProps = {
  open: boolean;
  onToggle: () => void;
  email: string;
  signOut: string | null; // null: the auth provider has no session to end → no Sign out
  csrf: string;
  update?: string | null; // lib/updates notice: "v1.2.0 available" / "main +3", null = nothing newer known
  wrap?: RefObject<HTMLDivElement>;
  btn?: RefObject<HTMLButtonElement>;
};

export function SettingsView({ open, onToggle, email, signOut, csrf, update = null, wrap, btn }: ViewProps) {
  const id = useId();
  return (
    <div className="settings" ref={wrap}>
      <button
        ref={btn}
        type="button"
        className="btn small settings-toggle"
        aria-label={update ? `Settings · ${update}` : "Settings"}
        title={update ? `Settings · ${update}` : "Settings"}
        aria-haspopup="true"
        aria-expanded={open}
        aria-controls={`${id}-menu`}
        onClick={onToggle}
      >
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
          <path
            fill="currentColor"
            d="M19.14 12.94a7.07 7.07 0 0 0 0-1.88l2.03-1.58a.5.5 0 0 0 .12-.64l-1.92-3.32a.5.5 0 0 0-.6-.22l-2.39.96a7.03 7.03 0 0 0-1.63-.94l-.36-2.54a.5.5 0 0 0-.5-.42h-3.84a.5.5 0 0 0-.5.42l-.36 2.54c-.59.24-1.13.56-1.63.94l-2.39-.96a.5.5 0 0 0-.6.22L2.65 8.84a.5.5 0 0 0 .12.64l2.03 1.58a7.07 7.07 0 0 0 0 1.88l-2.03 1.58a.5.5 0 0 0-.12.64l1.92 3.32c.13.22.39.3.6.22l2.39-.96c.5.38 1.04.7 1.63.94l.36 2.54c.05.24.25.42.5.42h3.84c.25 0 .45-.18.5-.42l.36-2.54c.59-.24 1.13-.56 1.63-.94l2.39.96c.22.08.47 0 .6-.22l1.92-3.32a.5.5 0 0 0-.12-.64l-2.03-1.58ZM12 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7Z"
          />
        </svg>
        {update && <i className="settings-dot" aria-hidden="true" />}
      </button>
      <div className="settings-menu" id={`${id}-menu`} role="group" aria-label="Settings" hidden={!open}>
        {email && <div className="settings-who">{email}</div>}
        <Link className="settings-link" to="/settings">
          Agents &amp; launchers
        </Link>
        <Link className="settings-link" to="/settings/agent-rules">
          Agent rules
        </Link>
        <Link className="settings-link" to="/settings/daily-report">
          Daily report
        </Link>
        <Link className="settings-link" to="/settings/runtime">
          Runtime
        </Link>
        <Link className="settings-link" to="/settings/git-hosts">
          Git hosts
        </Link>
        <Link className="settings-link" to="/settings/shortcuts">
          Shortcuts
        </Link>
        <Link className="settings-link" to="/settings/updates">
          Updates
          {update && <span className="tag settings-update">{update}</span>}
        </Link>
        <Link className="settings-link" to="/hello">
          Setup
        </Link>
        <div className="settings-row">
          <span className="settings-label">Skin</span>
          <SkinSwitch />
        </div>
        {signOut && (
          <form method="post" action={signOut}>
            <input type="hidden" name="_csrf_token" value={csrf} />
            <button className="btn settings-signout">Sign out</button>
          </form>
        )}
      </div>
    </div>
  );
}
