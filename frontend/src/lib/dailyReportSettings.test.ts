// Settings → Daily report: the revision ↔ form round trip, the runner picked from the host allowlist.
import { describe, expect, it } from "vitest";
import {
  entryLine,
  fromDraft,
  hasRunner,
  pageKeys,
  pickRunner,
  runnerIndex,
  sameDoc,
  toDraft,
  type DailyDoc,
  type DailyReportSettingsData,
} from "./dailyReportSettings";

const DOC: DailyDoc = {
  schedule: "*-*-* *:00/10:00",
  cutoff: "23:30",
  probe_timeout: 60,
  run_timeout: "90m",
  gateway: "http://127.0.0.1:8000/v1",
  model: "served",
  agent_model: "served",
  context_length: 131072,
  runner: { type: "hermes", command: "hermes", home: "/h/a", max_children: 16 },
};
const data = (over: Partial<DailyReportSettingsData> = {}): DailyReportSettingsData => ({
  revision: { id: 3, author: "op", at: 0 },
  doc: DOC,
  runners: [
    { type: "hermes", command: "hermes", home: "/h/a" },
    { type: "hermes", command: "hermes2", home: "/h/b" },
  ],
  host_keys: { hermes: ["command", "home"] },
  runner_keys: { hermes: ["command", "home", "max_children"] },
  history: [{ id: 3, author: "op", at: 0 }],
  revisions: 1,
  error: null,
  ...over,
});

describe("dailyReportSettings", () => {
  it("round trip: the saved doc comes back unchanged, integers as numbers", () => {
    const d = data();
    expect(fromDraft(d, toDraft(d))).toEqual(DOC);
    expect(sameDoc(fromDraft(d, toDraft(d)), DOC)).toBe(true);
  });

  it("the runner is the allowlist entry it equals on the host keys; the page edits only the rest", () => {
    const d = data();
    expect(runnerIndex(d, DOC.runner)).toBe(0);
    expect(pageKeys(d, "hermes")).toEqual(["max_children"]);
    const picked = pickRunner(d, toDraft(d), 1);
    expect(fromDraft(d, picked).runner).toEqual({
      type: "hermes",
      command: "hermes2",
      home: "/h/b",
      max_children: 16,
    });
  });

  it("a saved runner the host dropped is kept as saved (-1), never swapped for an allowed one", () => {
    const d = data({
      runners: [{ type: "hermes", command: "other", home: "/x" }],
    });
    const draft = toDraft(d);
    expect(draft.runner).toBe(-1);
    expect(fromDraft(d, draft).runner).toEqual(DOC.runner);
  });

  it("never saved: empty fields, NO runner picked (Save waits); a non-integer stays text for the server to refuse", () => {
    const d = data({ revision: null, doc: null, history: [] });
    let draft = toDraft(d);
    expect(draft.fields.schedule).toBe("");
    expect(draft.runner).toBe(-1);
    expect(hasRunner(draft)).toBe(false);
    draft = pickRunner(d, draft, 0);
    expect(hasRunner(draft)).toBe(true);
    draft.fields.probe_timeout = "6o";
    draft.extra.max_children = "4";
    const doc = fromDraft(d, draft);
    expect(doc.probe_timeout).toBe("6o");
    expect(doc.runner).toEqual({
      type: "hermes",
      command: "hermes",
      home: "/h/a",
      max_children: 4,
    });
  });

  it("an allowlist entry reads as one line", () => {
    expect(entryLine({ type: "hermes", command: "hermes", home: "/h/a" })).toBe("hermes: command hermes · home /h/a");
  });
});
