// Settings → Runtime's stylesheet, read as written: every colour is a skin token (so Light, Dark and any
// skin file hold), nothing follows the system scheme, and the rules that keep the page inside a 390 px phone are
// there. No layout engine here: the rendered check is a browser QA pass.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const raw = readFileSync(new URL("../styles/runtime.css", import.meta.url), "utf8");
const css = raw.replace(/\/\*[\s\S]*?\*\//g, "");
const skin = (name: string) => readFileSync(new URL(`../../../skins/${name}.yml`, import.meta.url), "utf8");
// the declarations of every rule whose selector list has `sel` as a whole selector (media / container blocks included)
const rules = (sel: string): string => {
  const out: string[] = [];
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const sels = m[1]!.split(",").map((s) => s.trim().replace(/\s+/g, " "));
    if (sels.includes(sel)) out.push(m[2]!);
  }
  if (!out.length) throw new Error(`runtime.css has no rule for ${sel}`);
  return out.join("\n");
};

describe("runtime.css colours", () => {
  it("has no colour literal: no hex, no rgb()/hsl() of plain numbers, no named colour", () => {
    expect(css.match(/#[0-9a-fA-F]{3,8}\b/g)).toBeNull();
    expect(css.match(/\b(?:rgba?|hsla?|oklch|oklab)\(\s*[\d.]/g)).toBeNull();
    const colours = [...css.matchAll(/(?:^|[;{\s])(?:color|background|background-color|border-color):\s*([^;]+);/g)];
    expect(colours.length).toBeGreaterThan(10);
    for (const [, v] of colours) expect(v).toMatch(/var\(--|^inherit$|^transparent$/);
  });
  it("uses only tokens both base skins define (or app.css's -rgb / radius / shadow / font derivatives)", () => {
    const [light, dark] = [skin("light"), skin("dark")];
    const derived = /^--(?:(?:ok|warn|bad|accent)-rgb|radius-[a-z-]+|shadow-[a-z-]+|mat-blur|mono)$/;
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
});

describe("runtime.css layout", () => {
  it("every grid track may shrink: the page never scrolls sideways", () => {
    expect(rules(".rt > *")).toMatch(/min-width:\s*0;/);
    for (const m of css.matchAll(/grid-template-columns:\s*([^;]+);/g)) {
      // a bare `1fr` track has an automatic minimum (its content): only minmax(0, …) or fixed tracks
      expect(m[1]!.replace(/minmax\([^()]*(?:\([^()]*\)[^()]*)*\)/g, ""), m[0]).not.toMatch(/\dfr/);
    }
  });
  it("a phone stacks each key: its name over the input, the duration and the note", () => {
    const phone = css.match(/@media \(max-width: 640px\) \{[\s\S]*?\.rt-row \{([^}]*)\}/);
    expect(phone?.[1]).toMatch(/"name name name"\s*"input human note"/);
  });
});
