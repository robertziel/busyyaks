// The header's settings cog: closed = only the cog; open = account, the Agents & launchers link, the skin choice
// (current one checked), Sign out.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SettingsView } from "./Settings";

const render = (p: Partial<Parameters<typeof SettingsView>[0]> = {}) =>
  renderToStaticMarkup(
    createElement(
      MemoryRouter,
      null,
      createElement(SettingsView, {
        open: false,
        onToggle: () => {},
        email: "op@example.test",
        signOut: "/logout",
        csrf: "tok<1>",
        ...p,
      }),
    ),
  );

describe("SettingsView", () => {
  beforeEach(() => {
    vi.stubGlobal("window", {
      busyyaksSkin: { choices: ["light", "dark", "auto"], get: () => "dark", set: () => {} },
    });
  });
  afterEach(() => vi.unstubAllGlobals());

  it("closed: the cog, labelled, collapsed; the menu hidden", () => {
    const html = render();
    expect(html).toMatch(/<button[^>]*aria-label="Settings"[^>]*aria-expanded="false"/);
    expect(html).toMatch(/class="settings-menu"[^>]*hidden=""/);
  });

  it("open: account, the three skins with the current one checked, Sign out posting the CSRF token", () => {
    const html = render({ open: true });
    expect(html).toMatch(/aria-expanded="true"/);
    expect(html).not.toMatch(/hidden=""/);
    expect(html).toContain('<div class="settings-who">op@example.test</div>');
    expect(html).toMatch(/<a class="settings-link" href="\/settings"[^>]*>Agents &amp; launchers<\/a>/);
    expect(html).toMatch(/<a class="settings-link" href="\/settings\/daily-report"[^>]*>Daily report<\/a>/);
    expect(html).toMatch(/<a class="settings-link" href="\/hello"[^>]*>Setup \(hello screen\)<\/a>/);
    expect(html.match(/role="radio"/g)).toHaveLength(3);
    expect(html).toMatch(/aria-checked="true" class="on">Dark</);
    expect(html).toMatch(/aria-checked="false">Light</);
    expect(html).toContain('<form method="post" action="/logout">');
    expect(html).toContain('value="tok&lt;1&gt;"');
    expect(html).toContain(">Sign out</button>");
  });

  it("no session to end (provider none): no Sign out form", () => {
    const html = render({ open: true, signOut: null, csrf: "" });
    expect(html).not.toContain("<form");
    expect(html).not.toContain("Sign out");
  });
});
