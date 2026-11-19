// The Agents sidebar's row stylesheet, read as written: text contrast on every layer a row draws — at
// rest, hovered and open, the open body included — in both skins (WCAG 2.x, ≥ 4.5:1), and the rules that keep the
// name, the open body, a dialog and its keys inside a 296 px rail. No layout engine here: the layout facts are the
// declarations that produce them (the rendered layout is checked by hand in a browser).
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync(new URL("../styles/agents.css", import.meta.url), "utf8");
// the declarations of every rule whose selector list has `sel` as a whole selector
const rules = (sel: string): string => {
  const out: string[] = [];
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const sels = m[1]!
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .split(",")
      .map((s) => s.trim().replace(/\s+/g, " "));
    if (sels.includes(sel)) out.push(m[2]!);
  }
  if (!out.length) throw new Error(`agents.css has no rule for ${sel}`);
  return out.join("\n");
};
const decl = (sel: string, prop: string): string => {
  const all = [...rules(sel).matchAll(new RegExp(`(?:^|[;\\s])${prop}:\\s*([^;]+);`, "g"))];
  if (!all.length) throw new Error(`${sel} declares no ${prop}`);
  return all
    .at(-1)![1]!
    .replace(/\s*\/\*[\s\S]*?\*\//g, "")
    .trim();
};

type Rgb = [number, number, number];
type Rgba = [number, number, number, number];
const skin = (name: string) => {
  const y = readFileSync(new URL(`../../../skins/${name}.yml`, import.meta.url), "utf8");
  return (t: string): Rgba => {
    const v = y.match(new RegExp(`"--${t}":\\s*"([^"]+)"`))?.[1];
    if (!v) throw new Error(`skins/${name}.yml has no --${t}`);
    if (v.startsWith("#")) return [...([1, 3, 5].map((i) => parseInt(v.slice(i, i + 2), 16)) as Rgb), 1];
    const n = v.match(/[\d.]+/g)!.map(Number);
    return [n[0]!, n[1]!, n[2]!, n[3] ?? 1];
  };
};
const over = (f: Rgba, g: Rgb): Rgb => [0, 1, 2].map((i) => f[i]! * f[3] + g[i]! * (1 - f[3])) as Rgb;
const solid = (c: Rgba): Rgb => [c[0], c[1], c[2]];
const mix = (a: Rgb, pct: number, b: Rgb): Rgb => a.map((v, i) => (v * pct + b[i]! * (100 - pct)) / 100) as Rgb;
const lum = (c: Rgb) => {
  const [r, g, b] = c.map((v) => {
    const x = v / 255;
    return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
};
const ratio = (a: Rgb, b: Rgb) => {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x! + 0.05) / (y! + 0.05);
};

describe.each(["light", "dark"])("contrast, %s skin", (name) => {
  const s = skin(name);
  const ink = (t: string) => solid(s(t));
  const rail = over(s("mat-card"), ink("bg")); // .agents: the card material over the page
  // a row's tint as agents.css writes it: rgba(var(--<t>-rgb), a) or color-mix(in srgb, var(--<t>) N%, transparent)
  const tint = (sel: string): Rgba => {
    const v = decl(sel, "background");
    const a = v.match(/^rgba\(var\(--([\w-]+)-rgb\), ([\d.]+)\)$/);
    if (a) return [...ink(a[1]!), Number(a[2])];
    const m = v.match(/^color-mix\(in srgb, var\(--([\w-]+)\) (\d+)%, transparent\)$/);
    if (m) return [...ink(m[1]!), Number(m[2]) / 100];
    throw new Error(`${sel}: background ${v} is not a tint this test reads`);
  };
  const newTag = decl(".ag-tag.ag-new", "color").match(
    /^color-mix\(in srgb, var\(--vivid-teal\) (\d+)%, var\(--ink\)\)$/,
  );
  const unread = mix(ink("vivid-teal"), Number(newTag?.[1]), ink("ink"));
  const layers: [string, Rgb][] = [
    ["plain row", rail],
    ["plain row hovered / open", over(s("mat-fill-2"), rail)],
    ["blocked row", over(tint(".ag-s.st-blocked"), rail)],
    ["review row", over(tint(".ag-s.st-review"), rail)],
    ["open body of a tinted row", ink("panel")],
  ];

  it("the unread tag is a mix this test can read", () => expect(newTag).not.toBeNull());

  it("a hovered or open row draws ONE layer: no second tint under its text", () => {
    for (const sel of [".ag-s[open] > summary:hover", ".ag-s.st-blocked > summary:hover"])
      expect(decl(sel, "background"), sel).toBe("transparent");
    expect(decl(".ag-s.st-review > summary:hover", "background")).toBe("transparent");
    // no rule deepens a tinted row when it opens
    expect(css).not.toMatch(/\.ag-s\.(st-blocked|st-review)\[open\]/);
    expect(css).not.toMatch(/\.ag-s\.ag-unread[^{,]*\[open\]/);
  });

  it("an unread row is not tinted, railed or bolded: it does not wait for the operator", () => {
    expect(css).not.toMatch(/\.ag-unread[^{]*\{[^}]*(background|inset|font-weight)/);
    expect(decl(".ag-unread > summary .ag-dot", "box-shadow")).toMatch(/vivid-teal/);
  });

  it("an open tinted row's body sits on the panel", () => {
    for (const sel of [".ag-s.st-blocked > .ag-body", ".ag-s.st-review > .ag-body"])
      expect(decl(sel, "background"), sel).toBe("var(--panel)");
  });

  it.each(layers)("%s: every text colour a row draws is ≥ 4.5:1", (_, bg) => {
    const texts: [string, Rgb][] = [
      ["name / body text (--ink)", ink("ink")],
      ["detail, age, cards, facts (--ink-faint)", ink("ink-faint")],
      ["needs input + its why (--bad)", ink("bad")],
      ["PR review + its why (--warn)", ink("warn")],
      ["working / finished / N sub (--ok)", ink("ok")],
      ["unread tag", unread],
    ];
    for (const [what, c] of texts) expect(ratio(c, bg), what).toBeGreaterThanOrEqual(4.5);
    // the launcher tag: --ink-dim on its own fill over the layer
    expect(decl(".ag-eng", "color")).toBe("var(--ink-dim)");
    expect(ratio(ink("ink-dim"), over(s("mat-fill"), bg)), "launcher tag").toBeGreaterThanOrEqual(4.5);
  });

  // the open body's layers: a plain row's open fill, a tinted row's panel block
  const bodies = layers.filter(([name]) => name === "plain row hovered / open" || name === "open body of a tinted row");
  it.each(bodies)("%s: the copy chip (tmux attach …) is ≥ 4.5:1 on its fill", (_, bg) => {
    expect(ratio(ink("ink-faint"), over(s("mat-fill"), bg))).toBeGreaterThanOrEqual(4.5);
  });

  it("a terminal link keeps its resting fill when hovered in a row (the deeper one was under 4.5:1)", () => {
    expect(decl(".ag-body .termlink:hover", "background")).toBe("rgba(var(--accent-rgb), 0.12)");
    for (const [, bg] of bodies)
      expect(ratio(ink("accent"), over([...ink("accent"), 0.12], bg))).toBeGreaterThanOrEqual(4.5);
  });
});

describe("the row keeps to the rail (296 px drawer included)", () => {
  it("two columns only — the face and the row's lines: nothing beside the name but its age", () => {
    expect(decl(".ag-s summary", "grid-template-columns")).toBe("28px minmax(0, 1fr)");
  });
  it("the name wraps to a second line before it is cut; an open row shows it whole", () => {
    expect(decl(".ag-name", "overflow-wrap")).toBe("anywhere");
    expect(decl(".ag-name", "-webkit-line-clamp")).toBe("2");
    expect(decl(".ag-s[open] .ag-name", "display")).toBe("block");
  });
  it("line 2: the state word is never cut, the detail is", () => {
    expect(decl(".ag-tag", "flex")).toBe("none");
    expect(decl(".ag-detail", "min-width")).toBe("min(8em, 100%)");
    expect(decl(".ag-detail", "text-overflow")).toBe("ellipsis");
    expect(decl(".ag-eng", "max-width")).toBe("50%");
  });
  it("line 2: a card's tag (CI wait · ext. wait) is never cut; the whole words wrap, never past the row", () => {
    expect(decl(".ag-flag", "flex")).toBe("none");
    expect(decl(".ag-flag", "white-space")).toBe("nowrap");
    expect(decl(".ag-l2", "flex-wrap")).toBe("wrap");
  });
  it("hit targets: a row, the idle toggle and a dialog's keys are 40 px", () => {
    expect(decl(".ag-s summary", "min-height")).toBe("40px");
    expect(decl(".ag-more", "min-height")).toBe("40px");
    expect(decl(".ag-opts .btn", "min-height")).toBe("40px");
  });
  it("a long project label is cut, never run under the idle toggle", () => {
    expect(decl(".ag-glabel", "text-overflow")).toBe("ellipsis");
    expect(decl(".ag-gl", "min-width")).toBe("0");
    expect(decl(".ag-more", "flex")).toBe("none");
  });
  it("the open body: one column that may shrink, lines with no space break (waiting_for, a screen error, a 422)", () => {
    expect(decl(".ag-body", "grid-template-columns")).toBe("minmax(0, 1fr)");
    expect(decl(".ag-body", "overflow-wrap")).toBe("anywhere");
    expect(decl(".ag-body .copychip", "max-width")).toBe("100%");
    expect(decl(".ag-body .copychip code", "white-space")).toBe("normal");
    expect(decl(".ag-body .ag-err .dot", "flex")).toBe("none");
  });
  it("a review card's title shrinks so its PR link stays in the row", () => {
    expect(decl(".ag-rev a:first-child", "min-width")).toBe("0");
    expect(decl(".ag-rev a:first-child", "text-overflow")).toBe("ellipsis");
    expect(decl(".ag-rev a:last-child", "white-space")).toBe("nowrap");
  });
  it("a dialog: the command, the question and every key (Esc too) wrap inside the row", () => {
    expect(decl(".ag-dialog", "grid-template-columns")).toBe("minmax(0, 1fr)");
    expect(decl(".ag-dialog pre", "white-space")).toBe("pre-wrap");
    expect(decl(".ag-dialog pre", "word-break")).toBe("break-word");
    expect(decl(".ag-q", "overflow-wrap")).toBe("anywhere");
    expect(decl(".ag-opts", "flex-wrap")).toBe("wrap");
    expect(decl(".ag-opts .btn", "white-space")).toBe("normal");
    expect(decl(".ag-opts .btn", "max-width")).toBe("100%");
  });
});
