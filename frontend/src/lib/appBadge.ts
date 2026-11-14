// The installed desktop app's icon badge: the "N waiting for you" total on the dock / taskbar icon, set
// from the same /api/waiting read the header widget shows. The Badging API exists in Chromium browsers (an installed
// app shows it; a plain tab ignores it); where it does not exist there is no badge — nothing stands in for it.
// total = null: the count is unknown (the read failed) → the API's flag badge, a dot with no number: never 0 (that
// says "nothing waiting") and never the last count (a stale number shown as current). The header shows the error.
type BadgeNavigator = {
  setAppBadge?: (n?: number) => Promise<void>;
  clearAppBadge?: () => Promise<void>;
};

export function setAppBadge(total: number | null, nav: BadgeNavigator = navigator): void {
  if (!nav.setAppBadge || !nav.clearAppBadge) return;
  const done = total === null ? nav.setAppBadge() : total > 0 ? nav.setAppBadge(total) : nav.clearAppBadge();
  done.catch((e: unknown) => console.warn("app badge not set:", e));
}

// One /api/waiting read with its badge: the total on success, unknown (null) on a failure — the widget's load.
export function readWaiting<W extends { total: number }>(
  get: () => Promise<W>,
  onData: (w: W) => void,
  onError: (message: string) => void,
  nav: BadgeNavigator = navigator,
): Promise<void> {
  return get().then(
    (w) => {
      onData(w);
      setAppBadge(w.total, nav);
    },
    (e: unknown) => {
      setAppBadge(null, nav);
      onError(e instanceof Error ? e.message : String(e));
    },
  );
}
