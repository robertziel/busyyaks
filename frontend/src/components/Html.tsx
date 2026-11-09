// Server-rendered HTML (report bodies, notes, the component gallery — sanitized by Busyyaks::Markdown)
// injected as-is. Same-origin links inside it (sha → /commit/…, repo chips → /projects/…) navigate client-side.
import { forwardRef, useCallback, useEffect, useRef, type MouseEvent } from "react";
import { fitTables } from "../lib/fitTables";
import { useNavigate } from "react-router-dom";

export function useInterceptLinks() {
  const navigate = useNavigate();
  return (e: MouseEvent<HTMLElement>) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = (e.target as HTMLElement).closest("a");
    if (!a || !e.currentTarget.contains(a)) return;
    if (a.target && a.target !== "_self") return;
    if (a.hasAttribute("download") || a.classList.contains("kb-att-img")) return; // a file download / an attachment picture (the card dialog's lightbox)
    const url = new URL(a.href, window.location.href);
    if (url.origin !== window.location.origin) return;
    if (url.pathname === window.location.pathname && url.hash) return; // in-page anchor (contents rail)
    e.preventDefault();
    void navigate(url.pathname + url.search + url.hash); // BrowserRouter: navigate returns nothing to await
  };
}

type Props = { html: string; className?: string };

export const Html = forwardRef<HTMLDivElement, Props>(function Html({ html, className = "md" }, ref) {
  const onClick = useInterceptLinks();
  const box = useRef<HTMLDivElement | null>(null);
  const setRef = useCallback(
    (el: HTMLDivElement | null) => {
      box.current = el;
      if (typeof ref === "function") ref(el);
      else if (ref) ref.current = el;
    },
    [ref],
  );
  // wide tables zoom out (twice at most), then scroll; re-fitted when the box changes width
  useEffect(() => {
    const el = box.current;
    if (!el || !el.querySelector("table")) return;
    fitTables(el);
    let w = el.clientWidth;
    const ro = new ResizeObserver(() => {
      if (el.clientWidth !== w) {
        w = el.clientWidth;
        fitTables(el);
      }
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [html]);
  return <div ref={setRef} className={className} onClick={onClick} dangerouslySetInnerHTML={{ __html: html }} />;
});
