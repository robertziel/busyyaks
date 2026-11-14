// The frame every route shares: frosted header (brand, segmented nav, agents toggle, settings cog), the page,
// the agents rail (a drawer below 1180px), the flash.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Link, NavigationType, NavLink, Outlet, useLocation, useNavigationType } from "react-router-dom";
import { Agents, type AgentTotals } from "./Agents";
import { FlashView, useFlash } from "./Flash";
import { Search } from "./Search";
import { Settings } from "./Settings";
import { WaitingWidget } from "./Waiting";

export function Layout() {
  const location = useLocation();
  const navType = useNavigationType();
  const { flash, setFlash } = useFlash();
  const [drawer, setDrawer] = useState(false);
  const [totals, setTotals] = useState<AgentTotals | null>(null);
  const top = useRef<HTMLElement>(null);
  const asideRef = useRef<HTMLElement>(null);

  // the sticky toolbar / thead / rail offsets (CSS var --top-h) follow the header's real height
  useLayoutEffect(() => {
    const el = top.current;
    if (!el) return;
    const measure = () => document.documentElement.style.setProperty("--top-h", `${el.offsetHeight}px`);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // a flash belongs to the page it was raised for
  useEffect(() => {
    if (flash && flash.path !== location.pathname) setFlash(null);
  }, [location.pathname, flash, setFlash]);

  // new page → top (back/forward keep the browser's position); drawer closes
  useEffect(() => {
    if (navType === NavigationType.Push && !location.hash) window.scrollTo(0, 0);
    setDrawer(false);
  }, [location.pathname, location.hash, navType]);

  useEffect(() => {
    document.body.classList.toggle("agents-open", drawer);
    if (!drawer) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setDrawer(false);
    };
    const onDown = (e: PointerEvent) => {
      const t = e.target as HTMLElement;
      if (!asideRef.current?.contains(t) && !t.closest(".agents-toggle")) setDrawer(false);
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onDown);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onDown);
    };
  }, [drawer]);

  return (
    <>
      <header className="top" ref={top}>
        <div className="in">
          <Link className="brand" to="/" aria-label="busyyaks">
            <img className="logo-light" src="/static/logo-light-animated.svg" alt="" />
            <img className="logo-dark" src="/static/logo-dark-animated.svg" alt="" />
          </Link>
          <nav>
            <NavLink to="/" end>
              Today
            </NavLink>
            <NavLink to="/projects">Projects</NavLink>
            <NavLink to="/reports">Reports</NavLink>
            <NavLink to="/github">GitHub</NavLink>
            <NavLink to="/session-boards">Sessions</NavLink>
          </nav>
          <Search />
          <span className="spacer" />
          <button
            type="button"
            className="btn small agents-toggle"
            aria-expanded={drawer}
            aria-controls="agents"
            onClick={() => setDrawer((d) => !d)}
          >
            Agents <b>{totals?.busy ?? "·"}</b>
            {totals && totals.blocked > 0 && (
              <b className="ag-need" title="sessions stopped until you act">
                {totals.blocked}
              </b>
            )}
            {totals && totals.review > 0 && (
              <b className="ag-rev-n" title="sessions with a PR waiting for your review">
                {totals.review}
              </b>
            )}
          </button>
          <div data-auth-launcher />
          <Settings />
        </div>
      </header>
      <div className="shell">
        <main className="wrap">
          {flash && <FlashView flash={flash} onClose={() => setFlash(null)} />}
          <Outlet />
        </main>
        <aside className="agents" id="agents" aria-label="Agents" ref={asideRef}>
          <Agents onTotals={setTotals} />
        </aside>
      </div>
      <WaitingWidget />
    </>
  );
}
