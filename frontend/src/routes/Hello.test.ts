// The /hello wizard's skin parts: the step order, the Skin step's switch, the Ready step's skin fact —
// rendered to markup over a stub window.busyyaksSkin.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SetupData } from "../lib/hello";
import { ReadyFacts, STEPS, Skin } from "./Hello";

const LABELS: Record<string, string> = { light: "Light", dark: "Dark", auto: "Auto", matrix: "Matrix" };
function stub(choice: string) {
  vi.stubGlobal("window", {
    busyyaksSkin: { choices: Object.keys(LABELS), label: (c: string) => LABELS[c], get: () => choice, set: vi.fn() },
  });
}
afterEach(() => vi.unstubAllGlobals());

const data = {
  checks: [
    { key: "db", label: "database", ok: true, detail: "" },
    { key: "github", label: "github", ok: false, detail: "no run yet" },
  ],
  projects: { repos: 5 },
} as unknown as SetupData;

describe("Hello", () => {
  it("steps: Skin right after Welcome", () => {
    expect(STEPS).toEqual(["Welcome", "Skin", "Projects", "Agents", "Done"]);
  });

  it("Skin step: every skin choice, the current one checked", () => {
    stub("matrix");
    const html = renderToStaticMarkup(createElement(Skin));
    expect(html).toContain("<h2>Skin</h2>");
    expect(html.match(/role="radio"/g)).toHaveLength(4);
    expect(html).toMatch(/aria-checked="true" class="on">Matrix</);
  });

  it("Ready: the chosen skin's label first, then the other facts", () => {
    stub("dark");
    const html = renderToStaticMarkup(
      createElement(ReadyFacts, { data, summary: { launchers: ["claude", "hermes"], def: "claude" } }),
    );
    expect(html).toMatch(/^<dl class="hello-facts"><dt>skin<\/dt><dd>Dark<\/dd><dt>repos<\/dt><dd>5<\/dd>/);
    expect(html).toContain("claude · hermes");
    expect(html).toContain("<dt>checks</dt><dd>1/2 ok</dd>");
  });
});
