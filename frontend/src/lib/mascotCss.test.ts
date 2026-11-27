// The mascot stylesheet (card 672), read as written: every colour is a skin token (so Light, Dark and any
// skin file hold), nothing follows the system scheme, and the rules that keep it inside a 390 px phone are there. No layout engine here: the rendered check is the card's QA.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const raw = readFileSync(new URL("../styles/mascot.css", import.meta.url), "utf8");
const css = raw.replace(/\/\*[\s\S]*?\*\//g, "");
const skin = (name: string) => readFileSync(new URL(`../../../skins/${name}.yml`, import.meta.url), "utf8");
// the declarations of every rule whose selector list has `sel` as a whole selector (media / container blocks included)
const rules = (sel: string): string => {
  const out: string[] = [];
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const sels = m[1]!.split(",").map((s) => s.trim().replace(/\s+/g, " "));
    if (sels.includes(sel)) out.push(m[2]!);
  }
  if (!out.length) throw new Error(`mascot.css has no rule for ${sel}`);
  return out.join("\n");
};

describe("mascot.css colours", () => {
  it("has no colour literal: no hex, no rgb()/hsl() of plain numbers, no named colour", () => {
    expect(css.match(/#[0-9a-fA-F]{3,8}\b/g)).toBeNull();
    expect(css.match(/\b(?:rgba?|hsla?|oklch|oklab)\(\s*[\d.]/g)).toBeNull();
    const colours = [...css.matchAll(/(?:^|[;{\s])(?:color|background|background-color|border-color):\s*([^;]+);/g)];
    expect(colours.length).toBeGreaterThan(5);
    for (const [, v] of colours) expect(v).toMatch(/var\(--|^inherit$|^transparent$/);
  });
  it("uses only tokens both base skins define (or app.css's -rgb / radius / shadow / font derivatives)", () => {
    const [light, dark] = [skin("light"), skin("dark")];
    const derived = /^--(?:(?:ok|warn|bad|accent)-rgb|radius-[a-z-]+|shadow-[a-z-]+|mat-blur|t-small|w|m|depth)$/;
    const used = new Set([...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]!));
    expect(used.size).toBeGreaterThan(4);
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

describe("mascot.css layout", () => {
  it("text may shrink and long words wrap: a long path or error never scrolls the page sideways", () => {
    expect(rules(".mascot")).toMatch(/min-width:\s*0;/);
    expect(rules(".mascot-text")).toMatch(/min-width:\s*0;/);
    expect(rules(".mascot-detail")).toMatch(/overflow-wrap:\s*anywhere;/);
  });
  it("every art size is bounded in height and width", () => {
    for (const sel of [
      ".mascot-page .mascot-art svg",
      ".mascot-card .mascot-art svg",
      ".mascot-banner .mascot-art svg",
    ]) {
      expect(rules(sel)).toMatch(/(?:^|\s)height:/);
      expect(rules(sel)).toMatch(/max-width:/);
    }
  });
  it("a failed read's card stacks the yak over the words on a phone", () => {
    const phone = css.match(/@media \(max-width: 640px\) \{\s*\.mascot-card \{([^}]*)\}/);
    expect(phone?.[1]).toMatch(/flex-direction:\s*column;/);
  });
  it("the down banner spans the phone: two insets, centred by auto margins, never left: 50% + a transform", () => {
    const conn = readFileSync(new URL("../styles/connection.css", import.meta.url), "utf8").replace(
      /\/\*[\s\S]*?\*\//g,
      "",
    );
    const banner = conn.match(/\.conn-banner \{([^}]*)\}/)?.[1] ?? "";
    expect(banner).toMatch(/left:\s*16px;/);
    expect(banner).toMatch(/right:\s*16px;/);
    expect(banner).toMatch(/margin:\s*0 auto;/);
    expect(banner).toMatch(/width:\s*max-content;/);
    expect(banner).not.toMatch(/left:\s*50%|transform:/);
  });
});
