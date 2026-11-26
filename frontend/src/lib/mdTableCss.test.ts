// Markdown tables in card comments and descriptions, read as written in components.css: a GitHub chip in a
// table cell stays ONE pill (a commit shows its sha, the subject only in its title) instead of wrapping into pieces
// across a narrow column's lines, and a header row with every cell empty (`| | |`) draws nothing. The layout itself
// is checked in a browser, not here.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(new URL("../styles/components.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
// a selector list split at its top-level commas only (`:is(a, b)` stays one selector)
const split = (list: string): string[] => {
  const out = [""];
  let depth = 0;
  for (const ch of list) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) out.push("");
    else out[out.length - 1] += ch;
  }
  return out.map((s) => s.trim().replace(/\s+/g, " "));
};
const blocks = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sels: split(m[1]!), body: m[2]! }));
// the value the LAST rule naming `sel` as a whole selector gives `prop`
const decl = (sel: string, prop: string): string | undefined => {
  let v: string | undefined;
  for (const b of blocks) {
    if (!b.sels.includes(sel)) continue;
    const m = [...b.body.matchAll(new RegExp(`(?:^|[;\\s])${prop}:\\s*([^;]+);`, "g"))].at(-1);
    if (m) v = m[1]!.trim();
  }
  return v;
};
const inTd = (sel: string) => blocks.filter((b) => b.sels.some((s) => s.includes(".kb-md-body td") && s.includes(sel)));

describe("card markdown tables", () => {
  it("keeps a chip in a cell on one line, as one box", () => {
    expect(decl(".kb-md-body td .gh-ref", "white-space")).toBe("nowrap");
    expect(decl(".kb-md-body td .gh-ref", "display")).toBe("inline-flex");
  });

  it("never lets a chip's text wrap or break inside a cell", () => {
    expect(decl(".kb-md-body td .gh-ref > :is(code, span)", "overflow-wrap")).toBe("normal");
  });

  it("cuts a long chip label with an ellipsis so it never sets the column's width", () => {
    const text = ".kb-md-body td .gh-ref > :is(code, span)";
    expect(decl(text, "max-width")).toBe("28ch");
    expect(decl(text, "overflow")).toBe("hidden");
    expect(decl(text, "text-overflow")).toBe("ellipsis");
    // its own nowrap: a code label inherits a wrapping white-space from the markdown rules
    expect(decl(text, "white-space")).toBe("nowrap");
  });

  it("keeps the chip's whole text on one line", () => {
    for (const b of inTd(".gh-ref")) {
      expect(b.body).not.toMatch(/box-decoration-break/);
      expect(b.body).not.toMatch(/white-space:\s*normal/);
    }
  });

  it("shows a commit's sha only in a cell", () => {
    expect(decl(".kb-md-body td .gh-commit .gh-subj", "display")).toBe("none");
  });

  it("leaves a sentence's chips flowing with the words", () => {
    expect(decl(":is(.kb-md-body p, .kb-md-body li) .gh-ref", "box-decoration-break")).toBe("clone");
    expect(decl(":is(.kb-md-body p, .kb-md-body li) .gh-ref > :is(code, span)", "white-space")).toBe("normal");
  });

  it("scrolls a table wider than the dialog inside itself (app.css)", () => {
    const app = readFileSync(new URL("../../../public/static/app.css", import.meta.url), "utf8");
    const body = app.match(/\n\.md table \{([^}]*)\}/)?.[1] ?? "";
    expect(body).toMatch(/display:\s*block;/);
    expect(body).toMatch(/overflow-x:\s*auto;/);
    expect(body).toMatch(/max-width:\s*100%;/);
  });

  it("hides a header row whose cells are all empty", () => {
    expect(decl(".md thead:not(:has(th:not(:empty)))", "display")).toBe("none");
  });
});
