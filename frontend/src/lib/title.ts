import { useEffect } from "react";

// The tab title = the page's own title + a prefix the new-waiting alert sets (card 611: "(2 new) "); each part is
// written by its owner and the title is always both, so a route change never drops the alert nor the alert the page.
let page = "busyyaks";
let prefix = "";
const apply = () => {
  document.title = prefix + page;
};

export function setTitlePrefix(p: string): void {
  prefix = p;
  apply();
}

export function useTitle(title: string | undefined) {
  useEffect(() => {
    page = title ? `${title} · busyyaks` : "busyyaks";
    apply();
  }, [title]);
}
