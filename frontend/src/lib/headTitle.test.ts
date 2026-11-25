// a project's head label hover — the full sha when detached, the label otherwise, "—" when unread
import { describe, expect, it } from "vitest";
import { headTitle } from "./format";

describe("headTitle", () => {
  it("names the full sha of a detached HEAD", () => {
    expect(headTitle({ detached_sha: "a".repeat(40), head_label: "detached @ aaaaaaa" })).toBe(
      `detached HEAD at ${"a".repeat(40)}`,
    );
  });
  it("is the branch on a branch, a dash when unread", () => {
    expect(headTitle({ detached_sha: null, head_label: "main" })).toBe("main");
    expect(headTitle({ detached_sha: null, head_label: null })).toBe("—");
  });
});
