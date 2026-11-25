// Settings → Git hosts: each provider's card state, the collector's line, why Connect is off, a failed
// call as shown, the wizard's Summary line and the "not connected" sentence split at its link.
import { describe, expect, it } from "vitest";
import {
  testedLine,
  cardState,
  collectorLine,
  connectRefusal,
  failure,
  offParts,
  summaryLine,
  type GitHostConnection,
  type GitHostProvider,
} from "./gitHosts";

const github: GitHostProvider = { key: "github", label: "GitHub", available: true, note: null };
const gitlab: GitHostProvider = { key: "gitlab", label: "GitLab", available: false, note: "coming soon" };
const cur: GitHostConnection = {
  id: 3,
  provider: "github",
  label: "GitHub",
  login: "octocat",
  token_hint: "…abcd",
  author: "op",
  at: 1000,
};

describe("cardState", () => {
  it("connected when the current connection is this provider", () => {
    expect(cardState(github, cur)).toBe("connected");
  });
  it("open when nothing (or another provider) is connected and it is available", () => {
    expect(cardState(github, null)).toBe("open");
    expect(cardState(github, { ...cur, provider: "gitlab" })).toBe("open");
  });
  it("soon when the provider is not available, connected or not", () => {
    expect(cardState(gitlab, null)).toBe("soon");
    expect(cardState(gitlab, cur)).toBe("soon");
  });
});

describe("collectorLine", () => {
  it("no run yet: muted", () => {
    expect(collectorLine(null, 2000)).toEqual({ tone: "muted", text: "collector: no run yet" });
    expect(collectorLine({ ok: true, error: null, at: null }, 2000).tone).toBe("muted");
  });
  it("ok with its age", () => {
    expect(collectorLine({ ok: true, error: null, at: 1940 }, 2000)).toEqual({
      tone: "ok",
      text: "collector ok · 1m ago",
    });
  });
  it("failed with the error verbatim", () => {
    const l = collectorLine({ ok: false, error: "GitHub rejected the token (401)", at: 1940 }, 2000);
    expect(l.tone).toBe("bad");
    expect(l.text).toBe("collector failed 1m ago: GitHub rejected the token (401)");
  });
  it("failed with no reason recorded says so", () => {
    expect(collectorLine({ ok: false, error: null, at: 1940 }, 2000).text).toMatch(/no reason recorded$/);
  });
});

describe("connectRefusal", () => {
  it("off while empty or blank, with the reason", () => {
    expect(connectRefusal("", false, null, "github")).toBe("paste a token");
    expect(connectRefusal("   ", false, null, "github")).toBe("paste a token");
  });
  it("off while a call runs", () => {
    expect(connectRefusal("ghp_x", true, null, "github")).toBe("connecting…");
  });
  it("off while another provider is connected", () => {
    expect(connectRefusal("t", false, { ...cur, provider: "gitlab", label: "GitLab" }, "github")).toBe(
      "GitLab is connected: disconnect it first",
    );
  });
  it("on with a token", () => {
    expect(connectRefusal("ghp_x", false, null, "github")).toBeNull();
  });
});

describe("failure", () => {
  it("status and the server's words", () => {
    expect(failure(422, "GitHub refused the token: 401")).toEqual({
      text: "422 · GitHub refused the token: 401",
      mayApply: false,
    });
    expect(failure(503, "the github service is not reachable").mayApply).toBe(false);
  });
  it("a 504 may still have applied", () => {
    expect(failure(504, "the github service did not answer within 30 s").mayApply).toBe(true);
  });
  it("no status: the message alone", () => {
    expect(failure(0, "network error").text).toBe("network error");
  });
});

describe("summaryLine", () => {
  it("the connected host and its login, or optional", () => {
    expect(summaryLine(cur)).toBe("GitHub · octocat");
    expect(summaryLine(null)).toBe("not connected (optional)");
  });
});

describe("offParts", () => {
  it("splits the server's sentence at its last dash: the tail links", () => {
    expect(offParts("GitHub not connected — Settings → Git hosts")).toEqual({
      lead: "GitHub not connected — ",
      link: "Settings → Git hosts",
    });
  });
  it("a sentence with no dash keeps it whole and adds the link", () => {
    expect(offParts("GitHub not connected")).toEqual({
      lead: "GitHub not connected — ",
      link: "Settings → Git hosts",
    });
  });
});

describe("testedLine", () => {
  it("the token still answers as the connected login", () => {
    expect(testedLine({ ok: true, login: "octocat", same: true })).toBe("Token works: GitHub answers as octocat");
  });
  it("another login: says to connect again", () => {
    expect(testedLine({ ok: true, login: "other", same: false })).toBe(
      "Token works, but GitHub answers as other, not the connected login: connect it again",
    );
  });
});
