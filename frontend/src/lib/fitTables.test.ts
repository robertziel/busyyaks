import { describe, expect, it } from "vitest";
import { fitTables } from "./fitTables";

// minimal stand-ins: no DOM in the test runner
function table(cls = "") {
  const set = new Set(cls.split(" ").filter(Boolean));
  return {
    dataset: {} as Record<string, string>,
    classList: {
      contains: (c: string) => set.has(c),
      add: (c: string) => set.add(c),
      remove: (...cs: string[]) => cs.forEach((c) => set.delete(c)),
    },
    get className() {
      return [...set].join(" ");
    },
  };
}
const root = (t: ReturnType<typeof table>) => ({ querySelectorAll: () => [t] }) as unknown as HTMLElement;
const as = (f: (t: ReturnType<typeof table>) => boolean) => f as unknown as (t: HTMLElement) => boolean;

describe("fitTables", () => {
  it("zooms an overflowing table out at most twice", () => {
    const t = table();
    fitTables(root(t), () => true);
    expect(t.className).toBe("md-denser");
  });

  it("stops at the first level that fits", () => {
    const t = table();
    fitTables(
      root(t),
      as((x) => !x.classList.contains("md-dense")),
    );
    expect(t.className).toBe("md-dense");
  });

  it("leaves a fitting table alone", () => {
    const t = table();
    fitTables(root(t), () => false);
    expect(t.className).toBe("");
  });

  it("starts again from the server's level on a re-fit", () => {
    const t = table("md-dense");
    fitTables(root(t), () => true);
    expect(t.className).toBe("md-denser");
    fitTables(root(t), () => false);
    expect(t.className).toBe("md-dense");
  });
});
