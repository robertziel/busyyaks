import { describe, expect, it } from "vitest";
import { signOutTarget } from "./signOut";

describe("signOutTarget", () => {
  it("is the path the provider gives", () => expect(signOutTarget("/logout")).toBe("/logout"));
  it("is null with no session to end (provider none)", () => expect(signOutTarget("")).toBeNull());
  it("refuses anything but a same-origin path", () => {
    expect(() => signOutTarget("https://evil.test/logout")).toThrow();
    expect(() => signOutTarget("//evil.test")).toThrow();
  });
});
