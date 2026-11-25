// The project Settings tab's stylesheet, read as written: every colour is a skin token (so Light, Dark and any skin file
// hold), nothing follows the system scheme, and every grid track may shrink (a 390 px phone never scrolls sideways).
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(new URL("../styles/project-rules.css", import.meta.url), "utf8").replace(
  /\/\*[\s\S]*?\*\//g,
  "",
);
const skin = (name: string) => readFileSync(new URL(`../../../skins/${name}.yml`, import.meta.url), "utf8");

describe("project-rules.css", () => {
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
  it("every grid track may shrink", () => {
    for (const m of css.matchAll(/grid-template-columns:\s*([^;]+);/g)) {
      expect(m[1]!.replace(/minmax\([^()]*\)/g, ""), m[0]).not.toMatch(/\dfr/);
    }
  });
});
