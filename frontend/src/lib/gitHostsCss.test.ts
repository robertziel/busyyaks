// Settings → Git hosts' stylesheet, read as written: every colour is a skin token (so Light, Dark and any
// skin file hold), nothing follows the system scheme, no grid track that cannot shrink.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const raw = readFileSync(new URL("../styles/git-hosts.css", import.meta.url), "utf8");
const css = raw.replace(/\/\*[\s\S]*?\*\//g, "");
const skin = (name: string) => readFileSync(new URL(`../../../skins/${name}.yml`, import.meta.url), "utf8");

describe("git-hosts.css colours", () => {
  it("has no colour literal: no hex, no rgb()/hsl() of plain numbers, no named colour", () => {
    expect(css.match(/#[0-9a-fA-F]{3,8}\b/g)).toBeNull();
    expect(css.match(/\b(?:rgba?|hsla?|oklch|oklab)\(\s*[\d.]/g)).toBeNull();
    const colours = [...css.matchAll(/(?:^|[;{\s])(?:color|background|background-color|border-color):\s*([^;]+);/g)];
    expect(colours.length).toBeGreaterThan(10);
    for (const [, v] of colours) expect(v).toMatch(/var\(--|^inherit$|^transparent$/);
  });
  it("uses only tokens both base skins define (or app.css's -rgb / radius / font derivatives)", () => {
    const [light, dark] = [skin("light"), skin("dark")];
    const derived = /^--(?:(?:ok|warn|bad|accent)-rgb|radius-[a-z-]+|shadow-[a-z-]+|mono)$/;
    const used = new Set([...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]!));
    expect(used.size).toBeGreaterThan(8);
    for (const t of used) {
      if (derived.test(t)) continue;
      expect(light, `skins/light.yml ${t}`).toContain(`"${t}":`);
      expect(dark, `skins/dark.yml ${t}`).toContain(`"${t}":`);
    }
  });
  it("never follows the system colour scheme (skins are [data-skin])", () => {
    expect(css).not.toMatch(/prefers-color-scheme/);
  });
  it("the not-connected line is muted, never the red of a failed read", () => {
    const off = css.match(/\.gith-off \{([^}]*)\}/)?.[1] ?? "";
    expect(off).toMatch(/color:\s*var\(--ink-faint\)/);
    expect(off).not.toMatch(/--bad/);
  });
});

describe("git-hosts.css layout", () => {
  it("every grid track may shrink: the page never scrolls sideways", () => {
    expect(css).toMatch(/\.gith > \*,\s*\.gith-hosts > \* \{\s*min-width:\s*0;/);
    for (const m of css.matchAll(/grid-template-columns:\s*([^;]+);/g)) {
      expect(m[1]!.replace(/minmax\([^()]*\)/g, ""), m[0]).not.toMatch(/\dfr/);
    }
  });
  it("a phone stacks each fact: its name over its value", () => {
    const phone = css.match(/@media \(max-width: 640px\) \{[\s\S]*?\.gith-facts \{([^}]*)\}/);
    expect(phone?.[1]).toMatch(/grid-template-columns:\s*minmax\(0, 1fr\);/);
  });
});
