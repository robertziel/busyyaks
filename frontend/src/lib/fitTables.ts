// Tables wider than their box zoom out (md-dense, then md-denser — the same steps the server gives text-heavy
// tables); still too wide after two steps → the table scrolls sideways. Re-fitted when the box resizes, starting
// again from the server's level so a wider box gets the larger text back.
const STEPS = ["", "md-dense", "md-denser"] as const;

function level(t: HTMLElement): number {
  return t.classList.contains("md-denser") ? 2 : t.classList.contains("md-dense") ? 1 : 0;
}

function setLevel(t: HTMLElement, n: number) {
  t.classList.remove("md-dense", "md-denser");
  if (STEPS[n]) t.classList.add(STEPS[n]);
}

export function fitTables(
  root: HTMLElement,
  overflows: (t: HTMLElement) => boolean = (t) => t.scrollWidth > t.clientWidth + 1,
) {
  root.querySelectorAll<HTMLElement>("table").forEach((t) => {
    if (t.dataset.zbase === undefined) t.dataset.zbase = String(level(t));
    let n = Number(t.dataset.zbase);
    setLevel(t, n);
    while (n < 2 && overflows(t)) setLevel(t, ++n);
  });
}
