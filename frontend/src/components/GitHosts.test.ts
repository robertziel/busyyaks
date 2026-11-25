// The git host cards, rendered to markup: GitHub connected / not connected, GitLab disabled with nothing to
// press, a refusal verbatim, the in-page Disconnect confirmation, and the "not connected" line's link.
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import type { GitHostsData } from "../lib/gitHosts";
import { GitHostOff, ProviderCard, type CardProps } from "./GitHosts";

const providers = [
  { key: "github", label: "GitHub", available: true, note: null },
  { key: "gitlab", label: "GitLab", available: false, note: "coming soon" },
];
const off: GitHostsData = { providers, current: null, collector: null };
const on: GitHostsData = {
  providers,
  current: {
    id: 1,
    provider: "github",
    label: "GitHub",
    login: "octocat",
    token_hint: "…abcd",
    author: "op",
    at: 1000,
  },
  collector: { ok: false, error: "GitHub rejected the token (401)", at: 1900 },
};
const noop = () => {};
const card = (p: Partial<CardProps> & { key?: string }) =>
  renderToStaticMarkup(
    createElement(ProviderCard, {
      provider: providers[p.key === "gitlab" ? 1 : 0]!,
      data: off,
      token: "",
      onToken: noop,
      busy: false,
      failed: null,
      confirming: false,
      onConnect: noop,
      onAskDisconnect: noop,
      onTest: noop,
      tested: null,
      onDisconnect: noop,
      onCancel: noop,
      onReload: noop,
      now: 2000,
      ...p,
    }),
  );

describe("GitHub not connected", () => {
  it("a password input, the hint, Connect off with its reason", () => {
    const html = card({});
    expect(html).toContain('type="password"');
    expect(html).toContain("<code>gh auth token</code>");
    expect(html).toMatch(/<button type="submit" class="btn primary" aria-disabled="true">Connect<\/button>/);
    expect(html).toContain("paste a token");
  });
  it("Connect on once a token is typed; the token is never shown as text", () => {
    const html = card({ token: "ghp_secret" });
    expect(html).toMatch(/<button type="submit" class="btn primary">Connect<\/button>/);
    expect(html.replace(/value="ghp_secret"/, "")).not.toContain("ghp_secret");
  });
  it("a refusal verbatim under it; a 504 offers Reload", () => {
    const html = card({ failed: { key: "github", text: "422 · GitHub refused the token: 401", mayApply: false } });
    expect(html).toContain("422 · GitHub refused the token: 401");
    expect(html).not.toContain("Reload");
    const t = card({ failed: { key: "github", text: "504 · no answer", mayApply: true } });
    expect(t).toContain("the change may still apply");
    expect(t).toContain(">Reload</button>");
  });
});

describe("GitHub connected", () => {
  it("login, token hint, since + by, the collector's error, Disconnect", () => {
    const html = card({ data: on });
    expect(html).toContain("Connected as <b>octocat</b>");
    expect(html).toContain("…abcd");
    expect(html).toContain(" · op</dd>");
    expect(html).toContain("collector failed 1m ago: GitHub rejected the token (401)");
    expect(html).not.toContain('type="password"');
    expect(html).toMatch(/>Disconnect<\/button>/);
    expect(html).not.toContain("Cancel");
  });
  it("Test connection beside Disconnect, and the test's answer under them", () => {
    expect(card({ data: on })).toMatch(/>Test connection<\/button>/);
    const html = card({ data: on, tested: "Token works: GitHub answers as octocat" });
    expect(html).toContain('<p class="gith-ok" role="status">Token works: GitHub answers as octocat</p>');
    expect(card({ data: on, busy: true })).toContain("Testing…");
  });
  it("Disconnect asks in the page first", () => {
    const html = card({ data: on, confirming: true });
    expect(html).toContain("Disconnect GitHub?");
    expect(html).toContain(">Cancel</button>");
  });
});

describe("GitLab", () => {
  it("the same card, coming soon, every control disabled", () => {
    const html = card({ key: "gitlab", token: "leak" });
    expect(html).toContain('<span class="gith-badge soon">coming soon</span>');
    expect(html).toMatch(/<input[^>]*disabled=""/);
    expect(html).toMatch(/<button type="button" class="btn primary" disabled="">Connect<\/button>/);
    expect(html).not.toContain("leak");
    expect(html).not.toContain('type="submit"');
  });
});

describe("GitHostOff", () => {
  it("the sentence, its tail a link to Settings → Git hosts", () => {
    const html = renderToStaticMarkup(
      createElement(
        MemoryRouter,
        null,
        createElement(GitHostOff, { text: "GitHub not connected — Settings → Git hosts" }),
      ),
    );
    expect(html).toContain('<p class="gith-off muted">');
    expect(html).toMatch(/GitHub not connected — <a href="\/settings\/git-hosts"[^>]*>Settings → Git hosts<\/a>/);
  });
});
