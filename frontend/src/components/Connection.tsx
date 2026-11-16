// The header's server badge (a remote server's host name, accented) and the connection state. Connected on
// this machine shows nothing; reconnecting / down always show, and down dims the page under a banner: what is on screen
// is no longer live.
import { useEffect, useState } from "react";
import { initialHealth, nextHealth, POLL_MS, probe, remoteHost, sessionStore, type Health } from "../lib/connection";

export function useHealth(): Health {
  const [health, setHealth] = useState<Health>(initialHealth);
  useEffect(() => {
    let alive = true;
    let timer: number | undefined;
    const tick = async () => {
      const ok = await probe();
      if (!alive) return;
      setHealth((h) => nextHealth(h, ok));
      timer = window.setTimeout(() => void tick(), POLL_MS);
    };
    timer = window.setTimeout(() => void tick(), POLL_MS);
    return () => {
      alive = false;
      window.clearTimeout(timer);
    };
  }, []);
  return health;
}

const LABEL = { connected: "connected", reconnecting: "reconnecting…", down: "down" } as const;

export function ConnectionBadge({ health }: { health: Health }) {
  const [remote] = useState(() => remoteHost(window.location.search, sessionStore()));
  useEffect(() => {
    document.body.classList.toggle("conn-down", health.state === "down");
  }, [health.state]);
  if (!remote && health.state === "connected") return null;
  return (
    <span
      className={`conn conn-${health.state}${remote ? " conn-remote" : ""}`}
      role="status"
      title={remote ? `busyyaks on ${remote}, through an ssh forward (yaks remote connect)` : "this busyyaks server"}
    >
      <i aria-hidden="true" />
      {remote && <b>{remote}</b>}
      <span>{LABEL[health.state]}</span>
    </span>
  );
}

export function ConnectionBanner({ health }: { health: Health }) {
  if (health.state !== "down") return null;
  return (
    <div className="conn-banner" role="alert">
      Connection down — this page is not live. Retrying every {POLL_MS / 1000} s.
    </div>
  );
}
