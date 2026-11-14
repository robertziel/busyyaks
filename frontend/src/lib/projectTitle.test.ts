// The project page's title row: pinned under the header (its measured height, --top-h) while the page scrolls, and one
// line at every width — the name ends in an ellipsis, the tags never shrink — so the pinned band never grows on a phone.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const CSS = readFileSync(new URL("../styles/spa.css", import.meta.url), "utf8");
const block = (head: string) => {
  const i = CSS.indexOf(`\n${head} {`);
  expect(i, head).toBeGreaterThan(-1);
  return CSS.slice(i, CSS.indexOf("}", i) + 1);
};

describe("spa.css project title", () => {
  it("sticks under the header, below the tab's menus", () => {
    const h1 = block("h1.proj-title");
    expect(h1).toMatch(/position: sticky;/);
    expect(h1).toMatch(/top: var\(--top-h\);/);
    expect(h1).toMatch(/z-index: 4;/);
    expect(h1).toMatch(/flex-wrap: nowrap;/);
  });

  it("cuts a long name with an ellipsis and keeps the tags whole", () => {
    const name = block("h1.proj-title > .proj-name");
    for (const rule of ["min-width: 0;", "overflow: hidden;", "text-overflow: ellipsis;", "white-space: nowrap;"])
      expect(name).toContain(rule);
    expect(block("h1.proj-title > *")).toMatch(/flex: none;/);
  });

  it("puts the glass behind the text, fading out at the bottom", () => {
    const glass = block("h1.proj-title::before");
    expect(glass).toMatch(/z-index: -1;/);
    expect(glass).toMatch(/backdrop-filter: var\(--mat-blur\);/);
    expect(glass).toMatch(/mask-image: linear-gradient\(to bottom, #000 55%, transparent\);/);
  });
});
