// Spotlight for the whole app. The nav field opens a full-page results sheet; everything works from the
// keyboard like macOS Spotlight: ⌘K / Ctrl+K anywhere opens (and closes), typing searches every source
// (pages, projects, board cards + comments, commits, reports, notes, agent sessions), ↑/↓ move, Tab /
// Shift+Tab jump between groups, Home/End, ↵ opens, ⌘↵ / Ctrl+↵ opens in a new tab, Esc clears then closes.
// The first result is the Top Hit; the right pane previews the selected one. The sheet is portalled to <body>:
// the header's backdrop-filter would otherwise be the containing block of its position: fixed.
import { Fragment, useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router-dom";
import { ApiError, apiGet } from "../api";
import { ago } from "../lib/format";
import { get as storeGet, set as storeSet } from "../lib/store";
import { ProjectIcon } from "./ProjectIcon";
import type { SearchData, SearchGroup, SearchItem, SearchKind } from "../types";

const PAGES: SearchItem[] = [
  { kind: "page", title: "Today", subtitle: "stats · today's report · commits · active projects", href: "/" },
  {
    kind: "page",
    title: "Projects",
    subtitle: "every repo · tree · filters · launch · new project",
    href: "/projects",
  },
  { kind: "page", title: "Reports", subtitle: "daily and team reports", href: "/reports" },
  {
    kind: "page",
    title: "Report components",
    subtitle: "tl:* blocks the reports are built from",
    href: "/reports/components",
  },
  {
    kind: "page",
    title: "GitHub",
    subtitle: "network feed · repos starred and people followed by who you follow",
    href: "/github",
  },
];
const KIND_LABEL: Record<SearchKind, string> = {
  page: "Page",
  project: "Project",
  card: "Card",
  commit: "Commit",
  report: "Report",
  note: "Note",
  agent: "Agent",
};
const RECENT_KEY = "busyyaks.search.recent-items";
const RECENT_MAX = 8;

type Row = { group: string; item: SearchItem; id: string };

const isSearchItem = (x: unknown): x is SearchItem =>
  typeof x === "object" &&
  x !== null &&
  "href" in x &&
  typeof x.href === "string" &&
  "title" in x &&
  typeof x.title === "string" &&
  "kind" in x &&
  typeof x.kind === "string";

function recent(): SearchItem[] {
  try {
    const v: unknown = JSON.parse(storeGet(RECENT_KEY) || "[]"); // stored by an older build too: checked, not trusted
    return Array.isArray(v) ? v.filter(isSearchItem).slice(0, RECENT_MAX) : [];
  } catch {
    return [];
  }
}
function remember(item: SearchItem) {
  const { kind, title, subtitle, href, icon } = item;
  const list = [{ kind, title, subtitle, href, icon }, ...recent().filter((x) => x.href !== href)].slice(0, RECENT_MAX);
  storeSet(RECENT_KEY, JSON.stringify(list));
}

export function mark(text: string | undefined, q: string): ReactNode {
  if (!text) return null;
  const s = q.trim();
  if (!s) return text;
  const out: ReactNode[] = [];
  const low = text.toLowerCase();
  const needle = s.toLowerCase();
  let i = 0;
  let k = 0;
  for (;;) {
    const j = low.indexOf(needle, i);
    if (j < 0) break;
    if (j > i) out.push(text.slice(i, j));
    out.push(<mark key={k++}>{text.slice(j, j + s.length)}</mark>);
    i = j + s.length;
  }
  out.push(text.slice(i));
  return out;
}

function pageHits(q: string): SearchItem[] {
  const s = q.trim().toLowerCase();
  if (!s) return PAGES;
  return PAGES.filter((p) => p.title.toLowerCase().includes(s) || (p.subtitle || "").toLowerCase().includes(s));
}

export function Search() {
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [data, setData] = useState<SearchData | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [active, setActive] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const opener = useRef<HTMLElement | null>(null);

  const close = useCallback(() => {
    setOpen(false);
    opener.current?.focus?.();
  }, []);
  const show = useCallback(() => {
    opener.current = document.activeElement as HTMLElement | null;
    setOpen(true);
  }, []);

  // ⌘K / Ctrl+K anywhere
  useEffect(() => {
    const onKey = (e: globalThis.KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "k") {
        e.preventDefault();
        if (open) close();
        else show();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, close, show]);

  useEffect(() => {
    document.body.classList.toggle("search-open", open);
    if (open) requestAnimationFrame(() => input.current?.select());
  }, [open]);

  // debounced fetch, the previous one aborted
  useEffect(() => {
    const s = q.trim();
    if (!open || !s) {
      setData(null);
      setErr(null);
      setBusy(false);
      return;
    }
    const ctl = new AbortController();
    setBusy(true);
    const t = window.setTimeout(() => {
      apiGet<SearchData>(`/api/search?q=${encodeURIComponent(s)}`, ctl.signal).then(
        (d) => {
          setData(d);
          setErr(null);
          setBusy(false);
        },
        (e: unknown) => {
          if (ctl.signal.aborted) return;
          setErr(e instanceof ApiError ? `${e.status || ""} ${e.message}`.trim() : String(e));
          setBusy(false);
        },
      );
    }, 120);
    return () => {
      ctl.abort();
      window.clearTimeout(t);
    };
  }, [q, open]);

  // groups shown: Top Hit, Pages, then the server's groups
  const recentItems = useMemo(() => (open ? recent() : []), [open]);
  const groups: SearchGroup[] = useMemo(() => {
    const s = q.trim();
    const pages = pageHits(s);
    if (!s) {
      const rec = recentItems;
      return [
        ...(rec.length ? [{ key: "recent", label: "Recent", items: rec }] : []),
        { key: "pages", label: "Pages", items: pages },
      ];
    }
    const server = data && data.q === s ? data.groups : [];
    const all: SearchGroup[] = [...(pages.length ? [{ key: "pages", label: "Pages", items: pages }] : []), ...server];
    const firstPage = pages.find((p) => p.title.toLowerCase().startsWith(s.toLowerCase()));
    const top = firstPage ?? all.find((g) => g.items.length)?.items[0];
    if (!top) return all;
    return [
      { key: "top", label: "Top hit", items: [top] },
      ...all.map((g) => ({ ...g, items: g.items.filter((i) => i !== top) })).filter((g) => g.items.length || g.error),
    ];
  }, [q, data, recentItems]);

  const rows: Row[] = useMemo(
    () => groups.flatMap((g) => g.items.map((item, i) => ({ group: g.key, item, id: `sr-${g.key}-${i}` }))),
    [groups],
  );
  useEffect(() => setActive(0), [q, data]);
  const cur = rows[Math.min(active, rows.length - 1)];

  useEffect(() => {
    if (!cur) return;
    document.getElementById(cur.id)?.scrollIntoView({ block: "nearest" });
  }, [cur]);

  const go = (row: Row | undefined, newTab: boolean) => {
    if (!row) return;
    remember(row.item);
    if (newTab) {
      window.open(row.item.href, "_blank", "noopener");
      return;
    }
    setOpen(false);
    void navigate(row.item.href); // BrowserRouter: navigate returns nothing to await
  };

  const jumpGroup = (dir: 1 | -1) => {
    if (!rows.length) return;
    const starts = rows.map((r, i) => (i === 0 || rows[i - 1]?.group !== r.group ? i : -1)).filter((i) => i >= 0);
    const at = starts.filter((i) => i <= active).pop() ?? 0;
    const idx = starts.indexOf(at);
    setActive(starts[(idx + dir + starts.length) % starts.length] ?? 0);
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>) => {
    const n = rows.length;
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        if (n) setActive((a) => (a + 1) % n);
        break;
      case "ArrowUp":
        e.preventDefault();
        if (n) setActive((a) => (a - 1 + n) % n);
        break;
      case "Tab":
        e.preventDefault();
        jumpGroup(e.shiftKey ? -1 : 1);
        break;
      case "Home":
        if (e.ctrlKey || e.metaKey || !q) {
          e.preventDefault();
          setActive(0);
        }
        break;
      case "End":
        if (e.ctrlKey || e.metaKey || !q) {
          e.preventDefault();
          setActive(Math.max(n - 1, 0));
        }
        break;
      case "Enter":
        e.preventDefault();
        go(cur, e.metaKey || e.ctrlKey);
        break;
      case "Escape":
        e.preventDefault();
        if (q) setQ("");
        else close();
        break;
    }
  };

  const total = rows.length;

  return (
    <>
      <button type="button" className="search-trigger" onClick={show} aria-haspopup="dialog" aria-expanded={open}>
        <span className="search-glass" aria-hidden="true" />
        <span className="search-ph">Search everything</span>
        <kbd>⌘K</kbd>
      </button>
      {open &&
        createPortal(
          <div
            className="spotlight"
            role="dialog"
            aria-modal="true"
            aria-label="Search"
            onMouseDown={(e) => e.target === e.currentTarget && close()}
          >
            <div className="sp-panel">
              <div className="sp-bar">
                <span className="search-glass" aria-hidden="true" />
                <input
                  ref={input}
                  autoFocus
                  onFocus={(e) => e.currentTarget.select()}
                  className="sp-input"
                  value={q}
                  onChange={(e) => setQ(e.target.value)}
                  onKeyDown={onKey}
                  placeholder="Projects, cards, commits, reports, notes, agents…"
                  role="combobox"
                  aria-expanded="true"
                  aria-controls="sp-list"
                  aria-activedescendant={cur?.id}
                  aria-autocomplete="list"
                  spellCheck={false}
                  autoComplete="off"
                />
                <span className="sp-state">{busy ? "…" : q.trim() ? `${total}` : ""}</span>
                <kbd>esc</kbd>
              </div>
              <div className="sp-body">
                <div className="sp-list" id="sp-list" role="listbox" ref={list} aria-label="Results">
                  {err && <p className="sp-err">search failed: {err}</p>}
                  {groups.map((g) => (
                    <Fragment key={g.key}>
                      <div className="sp-group" role="presentation">
                        {g.label}
                        {g.total != null && g.total > g.items.length && (
                          <span>
                            {g.items.length} of {g.total}
                          </span>
                        )}
                      </div>
                      {g.error && (
                        <p className="sp-err">
                          {g.label}: {g.error}
                        </p>
                      )}
                      {g.items.map((item, i) => {
                        const idx = rows.findIndex((r) => r.group === g.key && r.item === item);
                        const on = idx === active;
                        return (
                          <div
                            key={`${g.key}-${i}`}
                            id={`sr-${g.key}-${i}`}
                            role="option"
                            aria-selected={on}
                            className={`sp-row k-${item.kind}${on ? " on" : ""}${g.key === "top" ? " top" : ""}`}
                            onMouseMove={() => idx !== active && setActive(idx)}
                            onMouseDown={(e) => {
                              e.preventDefault();
                              go(rows[idx], e.metaKey || e.ctrlKey);
                            }}
                          >
                            {item.kind === "project" ? (
                              <ProjectIcon slug={item.title} icon={item.icon} size={26} />
                            ) : (
                              <span className={`sp-ico ico-${item.kind}`} aria-hidden="true" />
                            )}
                            <span className="sp-txt">
                              <span className="sp-title">{mark(item.title, q)}</span>
                              {item.subtitle && <span className="sp-sub">{mark(item.subtitle, q)}</span>}
                            </span>
                            <span className="sp-kind">{KIND_LABEL[item.kind]}</span>
                          </div>
                        );
                      })}
                    </Fragment>
                  ))}
                  {q.trim() && !busy && !err && data && data.q === q.trim() && total === 0 && (
                    <p className="sp-none">0 results for “{q.trim()}”</p>
                  )}
                </div>
                <Preview item={cur?.item} q={q} />
              </div>
              <div className="sp-keys" aria-hidden="true">
                <span>
                  <kbd>↑</kbd>
                  <kbd>↓</kbd> move
                </span>
                <span>
                  <kbd>tab</kbd> group
                </span>
                <span>
                  <kbd>↵</kbd> open
                </span>
                <span>
                  <kbd>⌘</kbd>
                  <kbd>↵</kbd> new tab
                </span>
                <span>
                  <kbd>esc</kbd> {q ? "clear" : "close"}
                </span>
              </div>
            </div>
          </div>,
          document.body,
        )}
    </>
  );
}

function Preview({ item, q }: { item: SearchItem | undefined; q: string }) {
  if (!item)
    return (
      <aside className="sp-preview empty">
        <p className="muted">↑ ↓ to preview</p>
      </aside>
    );
  const meta = Object.entries(item.meta || {}).filter(([, v]) => v !== null && v !== undefined && v !== "");
  return (
    <aside className="sp-preview" aria-live="polite">
      {item.kind === "project" ? (
        <ProjectIcon slug={item.title} icon={item.icon} size={44} />
      ) : (
        <span className={`sp-ico big ico-${item.kind}`} aria-hidden="true" />
      )}
      <p className="sp-pkind">{KIND_LABEL[item.kind]}</p>
      <h3>{mark(item.title, q)}</h3>
      {item.subtitle && <p className="sp-psub">{mark(item.subtitle, q)}</p>}
      {item.snippet && <p className="sp-snip">{mark(item.snippet, q)}</p>}
      {(meta.length > 0 || item.at) && (
        <dl>
          {item.at ? (
            <>
              <dt>updated</dt>
              <dd>{ago(item.at)} ago</dd>
            </>
          ) : null}
          {meta.map(([k, v]) => (
            <Fragment key={k}>
              <dt>{k.replace(/_/g, " ")}</dt>
              <dd>{typeof v === "boolean" ? (v ? "yes" : "no") : String(v)}</dd>
            </Fragment>
          ))}
        </dl>
      )}
      <p className="sp-open">
        <kbd>↵</kbd> {item.href}
      </p>
    </aside>
  );
}
