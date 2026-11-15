// The skin switch (settings menu + the /hello Skin step) and skinName, over a stub window.busyyaksSkin — rendered to markup.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SkinSwitch, skinName } from "./Skin";

const LABELS: Record<string, string> = { light: "Light", dark: "Dark", auto: "Auto", matrix: "Matrix" };
function stub(choice: string) {
  vi.stubGlobal("window", {
    busyyaksSkin: { choices: Object.keys(LABELS), label: (c: string) => LABELS[c], get: () => choice, set: vi.fn() },
  });
}

afterEach(() => vi.unstubAllGlobals());

describe("Skin", () => {
  it("skinName: the current choice's label", () => {
    stub("matrix");
    expect(skinName()).toBe("Matrix");
    stub("auto");
    expect(skinName()).toBe("Auto");
  });

  it("SkinSwitch: every choice, the current one checked", () => {
    stub("dark");
    const html = renderToStaticMarkup(createElement(SkinSwitch));
    expect(html.match(/role="radio"/g)).toHaveLength(4);
    expect(html).toMatch(/aria-checked="true" class="on">Dark</);
    expect(html).toMatch(/aria-checked="false">Light</);
  });

  it("no skin.js → thrown, never a guessed skin", () => {
    vi.stubGlobal("window", {});
    expect(() => skinName()).toThrow(/skin\.js did not load/);
  });
});
