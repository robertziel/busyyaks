// The card dialog's Links rail: the text of a PR row's chips, its unassign ×, the reason form's button and
// refusal, read ≥ 4.5:1 (WCAG 2.x) in both base skins — computed from the REAL files: the vendored kanban.css (which
// colour each element mixes, at what share), config/kanban.example.yml `theme` (--ak-* → skin token) and skins/*.yml.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), "utf8");
const css = read("../vendor/agents_kanban/styles/kanban.css");
const theme = read("../../../config/kanban.example.yml");

type Rgba = [number, number, number, number];
const parse = (v: string): Rgba => {
  const hex = /^#([0-9a-f]{6})$/i.exec(v);
  if (hex) return [0, 2, 4].map((i) => parseInt(hex[1]!.slice(i, i + 2), 16)).concat(1) as Rgba;
  const m = /^rgba?\(([^)]+)\)$/.exec(v);
  if (!m) throw new Error(`not a colour: ${v}`);
  const n = m[1]!.split(",").map((x) => Number(x.trim()));
  return [n[0]!, n[1]!, n[2]!, n[3] ?? 1];
};
const over = (top: Rgba, under: Rgba): Rgba => {
  const a = top[3];
  return [0, 1, 2].map((i) => top[i]! * a + under[i]! * (1 - a)).concat(1) as Rgba;
};
// color-mix(in srgb, a P%, b) of two opaque colours; b = null → transparent (a at P % alpha)
const mix = (a: Rgba, pct: number, b: Rgba | null): Rgba =>
  b
    ? ([0, 1, 2].map((i) => (a[i]! * pct + b[i]! * (100 - pct)) / 100).concat(1) as Rgba)
    : [a[0], a[1], a[2], pct / 100];
const lum = (c: Rgba) => {
  const f = (v: number) => (v / 255 <= 0.03928 ? v / 255 / 12.92 : ((v / 255 + 0.055) / 1.055) ** 2.4);
  return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
};
const ratio = (a: Rgba, b: Rgba) => (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05);

// --ak-<name> → the skin's colour, through the theme's mapping
const skin = (name: string) => {
  const yml = read(`../../../skins/${name}.yml`);
  return (ak: string): Rgba => {
    const token = new RegExp(`^\\s*--ak-${ak}:\\s*var\\((--[\\w-]+)\\)`, "m").exec(theme)?.[1];
    if (!token) throw new Error(`config/kanban.example.yml theme maps no --ak-${ak}`);
    const value = new RegExp(`^\\s*"${token}":\\s*"([^"]+)"`, "m").exec(yml)?.[1];
    if (!value) throw new Error(`skins/${name}.yml has no ${token}`);
    return parse(value);
  };
};
// the body of the rule whose selector list ends with `selector`
const rule = (selector: string) => {
  const at = css.indexOf(`${selector} {`);
  if (at < 0) throw new Error(`kanban.css has no rule ${selector}`);
  return css.slice(at, css.indexOf("}", at));
};
// `color: color-mix(in srgb, var(--X) N%, var(--ak-ink))` in a rule → [X, N]
const inkMix = (body: string, prop = "color"): [string, number] => {
  const m = new RegExp(`${prop}: color-mix\\(in srgb, var\\(--([\\w-]+)\\) (\\d+)%, var\\(--ak-ink\\)\\)`).exec(body);
  if (!m) throw new Error(`no ${prop}: color-mix(… , var(--ak-ink)) in: ${body.slice(0, 80)}`);
  return [m[1]!, Number(m[2])];
};

// `<prop>: var(--ak-X)` in a rule → X; `<prop>: rgba(var(--ak-X-rgb), A)` → [X, A]
const akVar = (body: string, prop: string): string => {
  const m = new RegExp(`(?:^|[\\s;{])${prop}: var\\(--ak-([\\w-]+)\\)`).exec(body);
  if (!m) throw new Error(`no ${prop}: var(--ak-…) in: ${body.slice(0, 80)}`);
  return m[1]!;
};
const akTint = (body: string): [string, number] => {
  const m = /background: rgba\(var\(--ak-([\w-]+)-rgb\), ([\d.]+)\)/.exec(body);
  if (!m) throw new Error(`no background: rgba(var(--ak-…-rgb), a) in: ${body.slice(0, 80)}`);
  return [m[1]!, Number(m[2])];
};

// every base skin in skins/ (the files `base:` light / dark start from) — both are checked
describe.each(["light", "dark"])("Links rail text contrast, %s skin", (name) => {
  const ak = skin(name);
  const AA = 4.5;
  // every fill is read from its rule: a row at rest, a row hovered / with its form open — over the card dialog's
  // surface, the theme's panel (the one fill named here: the dialog's own rule is the engine's, and
  // test/unit/no_kanban_code_test.rb keeps its selector out of this app's code)
  const panel = ak("panel");
  const row = over(ak(akVar(rule(".ak-root .kb-links li.kb-link-row"), "background")), panel);
  const rowHover = over(ak(akVar(rule(".ak-root .kb-links li.kb-link-row:focus-within"), "background")), panel);
  const rowAsking = over(ak(akVar(rule(".ak-root .kb-links li.kb-link-row.asking"), "background")), panel);
  const rows = [row, rowHover, rowAsking];
  const tinted = ([tone, alpha]: [string, number], under: Rgba): Rgba => {
    const c = ak(tone);
    return over([c[0], c[1], c[2], alpha], under);
  };

  it.each(["ok", "warn", "bad", "done", "accent", "ink-faint"])(
    "a %s chip on its own tint, on every row fill",
    (tone) => {
      const tag = rule(".ak-root .kb-link-tag");
      const [, share] = inkMix(tag);
      const tint = Number(/background: color-mix\(in srgb, var\(--tag\) (\d+)%, transparent\)/.exec(tag)![1]);
      const toneVar = tone === "ink-faint" ? "muted" : tone === "accent" ? "info" : tone;
      expect(rule(`.ak-root .kb-link-tag.t-${toneVar}`)).toContain(`--tag: var(--ak-${tone})`);
      for (const under of rows) {
        const bg = over(mix(ak(tone), tint, null), under);
        expect(ratio(mix(ak(tone), share, ak("ink")), bg), `${tone} on ${under.join(",")}`).toBeGreaterThanOrEqual(AA);
      }
    },
  );

  it("the unassign ×: at rest on every row fill, and hovered / open on its red tint", () => {
    const rest = ak(akVar(rule(".ak-root .kb-links li.kb-link-row > .kb-link-unassign"), "color"));
    for (const under of rows) expect(ratio(rest, under)).toBeGreaterThanOrEqual(AA);
    const hot = rule('.ak-root .kb-links li.kb-link-row > .kb-link-unassign[aria-expanded="true"]');
    const [tone, share] = inkMix(hot);
    for (const under of rows) {
      const fg = mix(ak(tone.replace("ak-", "")), share, ak("ink"));
      expect(ratio(fg, tinted(akTint(hot), under))).toBeGreaterThanOrEqual(AA);
    }
  });

  it("the reason form on the open row: Unassign on its tint (rest + hover), the placeholder, the refusal", () => {
    const go = rule(".ak-root .kb-unassign-form .btn.danger");
    const [tone, share] = inkMix(go);
    const fg = mix(ak(tone.replace("ak-", "")), share, ak("ink"));
    expect(ratio(fg, tinted(akTint(go), rowAsking))).toBeGreaterThanOrEqual(AA);
    const goHover = rule(".ak-root .kb-unassign-form .btn.danger:hover:not(:disabled)");
    expect(ratio(fg, tinted(akTint(goHover), rowAsking))).toBeGreaterThanOrEqual(AA);
    const box = over(ak(akVar(rule(".ak-root .kb-unassign-form input"), "background")), rowAsking);
    const placeholder = ak(akVar(rule(".ak-root .kb-unassign-form input::placeholder"), "color"));
    expect(ratio(placeholder, box)).toBeGreaterThanOrEqual(AA);
    expect(ratio(ak(akVar(rule(".ak-root .kb-unassign-form input"), "color")), box)).toBeGreaterThanOrEqual(AA);
    const [errTone, errShare] = inkMix(rule(".ak-root .kb-unassign-err"));
    expect(ratio(mix(ak(errTone.replace("ak-", "")), errShare, ak("ink")), rowAsking)).toBeGreaterThanOrEqual(AA);
  });

  it("history: the struck label on every row fill", () => {
    const struck = ak(akVar(rule(".ak-root .kb-links li.kb-link-row.struck > a .kb-link-label"), "color"));
    for (const under of rows) expect(ratio(struck, under)).toBeGreaterThanOrEqual(AA);
  });
});
