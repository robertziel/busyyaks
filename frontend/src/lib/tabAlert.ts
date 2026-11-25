// The page side of card 611's alert (lib/newWaiting.ts decides): watches whether the operator looks at the app, keeps
// the shared "seen" set, and draws the alert into the title, the favicon and `<meta name="theme-color">`.
import { useEffect, useRef } from "react";
import { alertPass, dottedIcon, SEEN_KEY, titlePrefix, type AlertEnv } from "./newWaiting";
import { get, set } from "./store";
import { setTitlePrefix } from "./title";
import type { Waiting } from "./waiting";

const looking = () => !document.hidden && document.hasFocus();

// the shell's favicon, read once; its dotted copy is built per colour
let iconSvg: Promise<string> | null = null;
function iconText(href: string): Promise<string> {
  // a failed read is not kept: the next alert asks again
  iconSvg ??= fetch(href)
    .then((r) => {
      if (!r.ok) throw new Error(`favicon ${href}: HTTP ${r.status}`);
      return r.text();
    })
    .catch((e: unknown) => {
      iconSvg = null;
      throw e;
    });
  return iconSvg;
}

// the to-answer colour of the current skin (the waiting widget's `? N to answer` segment)
const alertColor = () => getComputedStyle(document.documentElement).getPropertyValue("--vivid-purple").trim();

// storage blocked (private mode, a policy): the store never throws, but nothing is kept, so every read is a baseline
// and the alert never shows — said once on the console, never a guess kept in memory instead
let blockedSaid = false;
function keep(v: string): void {
  set(SEEN_KEY, v);
  if (get(SEEN_KEY) !== v && !blockedSaid) {
    blockedSaid = true;
    console.warn(`${SEEN_KEY}: localStorage keeps nothing here — the new-waiting tab alert is off`);
  }
}

// the count drawn now (the favicon fetch lands later: it draws only if the alert still stands)
let drawn = 0;

function draw(fresh: number): void {
  drawn = fresh;
  setTitlePrefix(titlePrefix(fresh));
  const icon = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
  if (icon) {
    icon.dataset.href ??= icon.getAttribute("href") ?? "";
    const plain = icon.dataset.href;
    if (fresh === 0) icon.setAttribute("href", plain);
    else {
      const color = alertColor();
      // .catch after .then: a favicon that is not an SVG (dottedIcon throws) is said too, never an unhandled rejection
      iconText(plain)
        .then((svg) => {
          if (drawn > 0) icon.setAttribute("href", dottedIcon(svg, color));
        })
        .catch((e: unknown) => console.warn("new-waiting favicon dot not drawn:", e));
    }
  }
  let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"][data-alert]');
  if (fresh === 0) meta?.remove();
  else {
    if (!meta) {
      meta = document.createElement("meta");
      meta.name = "theme-color";
      meta.dataset.alert = "";
      document.head.appendChild(meta);
    }
    meta.content = alertColor();
  }
}

// `data` = the widget's latest /api/waiting read (null = none yet or failed: the alert keeps its last state)
export function useNewWaitingAlert(data: Waiting | null): void {
  const latest = useRef<Waiting | null>(null);
  latest.current = data;
  const shown = useRef(-1);

  // the widget leaving the page takes its alert with it
  useEffect(() => () => draw(0), []);

  useEffect(() => {
    const env: AlertEnv = { read: () => get(SEEN_KEY), write: keep, looking, draw };
    const run = () => {
      const w = latest.current;
      if (w) shown.current = alertPass(w, env, shown.current);
    };
    run();
    const onStorage = (e: StorageEvent) => {
      if (e.key === SEEN_KEY) run();
    };
    document.addEventListener("visibilitychange", run);
    window.addEventListener("focus", run);
    window.addEventListener("blur", run);
    window.addEventListener("storage", onStorage);
    return () => {
      document.removeEventListener("visibilitychange", run);
      window.removeEventListener("focus", run);
      window.removeEventListener("blur", run);
      window.removeEventListener("storage", onStorage);
    };
  }, [data]);
}
