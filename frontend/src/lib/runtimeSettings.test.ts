// Settings → Runtime: the revision ↔ form round trip and the watch-pass figure.
import { describe, expect, it } from "vitest";
import {
  changedKeys,
  fieldRefusal,
  fromDraft,
  groups,
  human,
  rebase,
  refusedKey,
  sameDoc,
  saveRefusal,
  toDraft,
  watchFigure,
  watchWindow,
  type RuntimeSettingsData,
} from "./runtimeSettings";

const DOC = {
  scan_interval_seconds: 60,
  writer_sync_seconds: 30,
  github_interval_seconds: 3600,
  github_ci_interval_seconds: 60,
  notifier_interval_seconds: 5,
  notifier_watch_seconds: 30,
  watchdog_grace_seconds: 60,
};
const data: RuntimeSettingsData = {
  revision: { id: 2, author: "op", at: 0 },
  doc: DOC,
  keys: Object.fromEntries(Object.keys(DOC).map((k) => [k, { env: k.toUpperCase(), about: k }])),
  min: 1,
  max: 86400,
  history: [{ id: 2, author: "op", at: 0 }],
  revisions: 2,
};

describe("runtime settings", () => {
  it("round-trips the revision unchanged", () => {
    expect(sameDoc(fromDraft(toDraft(data)), DOC)).toBe(true);
  });

  it("keeps the server's key order and sends whole numbers as numbers", () => {
    const d = { ...toDraft(data), scan_interval_seconds: " 90 " };
    expect(Object.keys(d)).toEqual(Object.keys(DOC));
    expect(fromDraft(d).scan_interval_seconds).toBe(90);
  });

  it("sends anything else as typed, for the server to refuse by name", () => {
    expect(fromDraft({ ...toDraft(data), scan_interval_seconds: "1.5" }).scan_interval_seconds).toBe("1.5");
    expect(fromDraft({ ...toDraft(data), scan_interval_seconds: "" }).scan_interval_seconds).toBe("");
  });

  it("shows the watch period against the CI poll window", () => {
    expect(watchWindow(DOC)).toEqual({ period: 30, window: 600 });
    expect(watchWindow({ ...DOC, notifier_interval_seconds: 45 })).toEqual({ period: 45, window: 600 });
    expect(watchWindow({ ...DOC, notifier_interval_seconds: 7, notifier_watch_seconds: 599 })).toEqual({
      period: 602,
      window: 600,
    });
    expect(watchWindow({ ...DOC, github_ci_interval_seconds: "x" })).toBeNull();
  });

  it("groups the keys by the service their description names, in the server's order", () => {
    const g = groups({
      scan_interval_seconds: { env: "SCAN_INTERVAL_SECONDS", about: "scanner: seconds between repo scans" },
      github_interval_seconds: { env: "GITHUB_INTERVAL_SECONDS", about: "github: seconds between network collections" },
      github_ci_interval_seconds: { env: "GITHUB_CI_INTERVAL_SECONDS", about: "github: seconds between PR / CI polls" },
      watchdog_grace_seconds: {
        env: "WATCHDOG_GRACE_SECONDS",
        about: "watchdog: seconds a gone session keeps its cards",
      },
      odd: { env: "ODD", about: "no service named" },
    });
    expect(g.map((x) => [x.service, x.fields.map((f) => f.key)])).toEqual([
      ["scanner", ["scan_interval_seconds"]],
      ["github", ["github_interval_seconds", "github_ci_interval_seconds"]],
      ["watchdog", ["watchdog_grace_seconds"]],
      ["", ["odd"]],
    ]);
    expect(g[0]!.fields[0]).toEqual({
      key: "scan_interval_seconds",
      label: "between repo scans",
      env: "SCAN_INTERVAL_SECONDS",
    });
    expect(g[2]!.fields[0]!.label).toBe("a gone session keeps its cards");
    expect(g[3]!.fields[0]!.label).toBe("no service named");
  });

  it("says a duration in its two largest units", () => {
    expect([1, 45, 60, 90, 600, 3600, 3661, 5400, 86400].map(human)).toEqual([
      "1 s",
      "45 s",
      "1 min",
      "1 min 30 s",
      "10 min",
      "1 h",
      "1 h 1 min",
      "1 h 30 min",
      "24 h",
    ]);
  });

  it("names why a field would be refused", () => {
    expect(fieldRefusal(" 60 ", 1, 86400)).toBeNull();
    expect(fieldRefusal("", 1, 86400)).toBe("required");
    expect(fieldRefusal("1.5", 1, 86400)).toBe("whole seconds");
    expect(fieldRefusal("-3", 1, 86400)).toBe("whole seconds");
    expect(fieldRefusal("0", 1, 86400)).toBe("1–86400 s");
    expect(fieldRefusal("86401", 1, 86400)).toBe("1–86400 s");
  });

  it("draws the watch period on the longer of period and window", () => {
    expect(watchFigure(DOC)).toEqual({ period: 30, window: 600, ok: true, spare: 570, fill: 0.05, mark: 1 });
    const over = watchFigure({ ...DOC, notifier_watch_seconds: 1200 })!;
    expect(over).toMatchObject({ period: 1200, window: 600, ok: false, spare: -600, fill: 1, mark: 0.5 });
    // equal is refused: the server wants the period BELOW the window
    expect(watchFigure({ ...DOC, notifier_watch_seconds: 600 })).toMatchObject({ ok: false, spare: 0 });
    expect(watchFigure({ ...DOC, notifier_watch_seconds: "" })).toBeNull();
    expect(watchFigure({ ...DOC, github_ci_interval_seconds: 0 })).toBeNull();
  });

  it("keeps Save off with the reason", () => {
    const loaded = toDraft(data);
    expect(saveRefusal(loaded, loaded, 1, 86400)).toBe("no changes");
    expect(saveRefusal({ ...loaded, scan_interval_seconds: " 60 " }, loaded, 1, 86400)).toBe("no changes");
    expect(changedKeys({ ...loaded, scan_interval_seconds: "90" }, loaded)).toEqual(["scan_interval_seconds"]);
    expect(saveRefusal({ ...loaded, scan_interval_seconds: "90" }, loaded, 1, 86400)).toBeNull();
    expect(saveRefusal({ ...loaded, scan_interval_seconds: "x" }, loaded, 1, 86400)).toBe(
      "scan_interval_seconds: whole seconds",
    );
    expect(saveRefusal({ ...loaded, notifier_watch_seconds: "600" }, loaded, 1, 86400)).toBe(
      "watch 600 s ≥ window 600 s",
    );
  });

  it("finds the field a refusal names", () => {
    const keys = Object.keys(DOC);
    expect(refusedKey("422 · scan_interval_seconds must be a whole number of seconds, 1..86400 (got 0)", keys)).toBe(
      "scan_interval_seconds",
    );
    expect(
      refusedKey("422 · a watch pass every 602 s (notifier_watch_seconds 599, …) must be below 600 s", keys),
    ).toBeNull();
    expect(refusedKey("409 · stale base", keys)).toBeNull();
  });

  it("keeps Save off while a newer revision than the base exists", () => {
    const loaded = toDraft(data);
    expect(saveRefusal({ ...loaded, scan_interval_seconds: "90" }, loaded, 1, 86400, 3)).toBe("rev 3 is newer");
    expect(saveRefusal(loaded, loaded, 1, 86400, 3)).toBe("rev 3 is newer");
  });

  describe("rebase onto the newest revision", () => {
    const loaded = toDraft(data);
    it("takes the newest value of every key the form did not change, keeps the changed ones", () => {
      const mine = { ...loaded, scan_interval_seconds: "90" };
      const newest = { ...loaded, watchdog_grace_seconds: "45" };
      const r = rebase(mine, loaded, newest);
      expect(r.draft).toEqual({ ...loaded, scan_interval_seconds: "90", watchdog_grace_seconds: "45" });
      expect(r.conflicts).toEqual({});
      expect(changedKeys(r.draft, newest)).toEqual(["scan_interval_seconds"]);
    });
    it("flags a key only when the other save changed that same key to another value", () => {
      const mine = { ...loaded, scan_interval_seconds: " 90 ", github_interval_seconds: "7200" };
      const newest = { ...loaded, scan_interval_seconds: "120", watchdog_grace_seconds: "45" };
      const r = rebase(mine, loaded, newest);
      expect(r.conflicts).toEqual({ scan_interval_seconds: { theirs: "120", mine: "90" } });
      expect(r.draft.scan_interval_seconds).toBe(" 90 "); // the form's text, as typed
      expect(r.draft.github_interval_seconds).toBe("7200");
      expect(r.draft.watchdog_grace_seconds).toBe("45");
    });
    it("both saves setting the same value: no conflict, nothing left to save for it", () => {
      const mine = { ...loaded, scan_interval_seconds: "90" };
      const newest = { ...loaded, scan_interval_seconds: "90" };
      const r = rebase(mine, loaded, newest);
      expect(r.conflicts).toEqual({});
      expect(changedKeys(r.draft, newest)).toEqual([]);
    });
    it("an edit typed back to the loaded value takes the newer revision's value", () => {
      const mine = { ...loaded, scan_interval_seconds: " 60 " };
      const newest = { ...loaded, scan_interval_seconds: "120" };
      const r = rebase(mine, loaded, newest);
      expect(r.draft.scan_interval_seconds).toBe("120");
      expect(r.conflicts).toEqual({});
    });
    it("an unedited form becomes the newest revision; its keys are the newest's", () => {
      const newest = { ...loaded, notifier_watch_seconds: "60", extra_seconds: "9" };
      const r = rebase(loaded, loaded, newest);
      expect(r.draft).toEqual(newest);
      expect(r.conflicts).toEqual({});
    });
  });
});
