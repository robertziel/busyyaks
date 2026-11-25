// The /hello wizard's skin parts: the step order, the Skin step's switch, the Ready step's skin fact —
// rendered to markup over a stub window.busyyaksSkin.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { GitHostsData } from "../lib/gitHosts";
import type { SetupData } from "../lib/hello";
import { PlanCard, ReadyFacts, RestartBoth, STEPS, Skin } from "./Hello";

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
  projects: { repos: 5, host_root: "" },
  daily_report: { configured: false, saved: false, schedule: null, reason: "no daily report settings saved" },
} as unknown as SetupData;

describe("Hello", () => {
  it("steps: Checks, Skin, Projects, Git host, Agents, Summary", () => {
    expect(STEPS).toEqual(["Checks", "Skin", "Projects", "Git host", "Agents", "Summary"]);
  });

  it("Skin step: every skin choice, the current one checked", () => {
    stub("matrix");
    const html = renderToStaticMarkup(createElement(Skin));
    expect(html).toContain('<h2 tabindex="-1">Skin</h2>');
    expect(html.match(/role="radio"/g)).toHaveLength(4);
    expect(html).toMatch(/aria-checked="true" class="on">Matrix</);
  });

  it("Ready: the chosen skin's label first, then the other facts", () => {
    stub("dark");
    const html = renderToStaticMarkup(
      createElement(ReadyFacts, {
        data,
        summary: {
          launchers: [
            { key: "claude", label: "claude", problem: null },
            { key: "hermes", label: "hermes", problem: "not found on the host" },
          ],
          def: "claude",
        },
      }),
    );
    expect(html).toMatch(/^<dl class="hello-facts"><dt>skin<\/dt><dd>Dark<\/dd><dt>repos<\/dt><dd>5<\/dd>/);
    expect(html).toContain(
      '<span class="">claude</span><span class="hello-bad">✗ hermes · not found on the host</span>',
    );
    expect(html).toContain('<dt>checks</dt><dd>1/2 ok<span class="hello-bad">✗ github</span></dd>');
    expect(html).toContain("✗ not set up");
  });
});

// the git host is optional — Summary names it, or says not connected (optional), never as an issue
describe("Ready: the git host", () => {
  const summary = { launchers: [{ key: "claude", label: "claude", problem: null }], def: "claude" };
  const providers = [{ key: "github", label: "GitHub", available: true, note: null }];
  const render = (current: unknown) => {
    stub("dark");
    return renderToStaticMarkup(
      createElement(ReadyFacts, {
        data,
        summary,
        gitHost: { data: { providers, current, collector: null } as unknown as GitHostsData },
      }),
    );
  };
  it("not connected (optional), muted", () => {
    expect(render(null)).toContain('<dt>git host</dt><dd><span class="muted">not connected (optional)</span></dd>');
  });
  it("the connected host and its login", () => {
    const cur = {
      id: 1,
      provider: "github",
      label: "GitHub",
      login: "octocat",
      token_hint: "…abcd",
      author: "op",
      at: 1,
    };
    expect(render(cur)).toContain('<dt>git host</dt><dd><span class="">GitHub · octocat</span></dd>');
  });
  it("left out when the wizard did not read it", () => {
    stub("dark");
    expect(renderToStaticMarkup(createElement(ReadyFacts, { data, summary }))).not.toContain("git host");
  });
});

// card 532: the shared .btn[aria-disabled] rule dims a button that carries the attribute at all, "false" included
describe("the Projects plan card's buttons", () => {
  const plan = {
    from: "/old",
    to: "/new",
    repos: 3,
    roots: [{ path: "/projects", host: "/new" }],
    trusted: [],
    loses_trust: [],
    services: ["web"],
    plan_id: "p",
  };
  const render = (busy: boolean) =>
    renderToStaticMarkup(createElement(PlanCard, { plan, busy, onApply: () => {}, onCancel: () => {} }));
  it("carries no aria-disabled while idle (else they render dimmed)", () => {
    expect(render(false)).not.toContain("aria-disabled");
  });
  it("says aria-disabled=true on Apply and Cancel while busy, and stays focusable (no disabled)", () => {
    const html = render(true);
    expect(html.match(/aria-disabled="true"/g)).toHaveLength(2);
    expect(html).not.toMatch(/ disabled=""/);
  });
});

// the audit's /hello Agents step: "deploy/install-launcher.shdocker compose restart web" — two commands read as one
describe("the restart line", () => {
  it("names its two commands apart: never run together as one word", () => {
    const html = renderToStaticMarkup(createElement(RestartBoth));
    const text = html.replace(/<[^>]+>/g, "");
    expect(text).toBe("deploy/install-launcher.sh then docker compose restart web");
  });
});
