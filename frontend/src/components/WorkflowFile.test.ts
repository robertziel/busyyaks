import { describe, expect, it } from "vitest";
import { workflowFileLines, type WorkflowFileState } from "./WorkflowFile";

const base: WorkflowFileState = {
  file: ".busyyaks/workflow.yml",
  path: "/h/r/.busyyaks/workflow.yml",
  applied_at: "2026-11-14T10:00:00Z",
  error: null,
  error_at: null,
  checked_at: "2026-11-14T10:00:00Z",
  stale: false,
};

describe("workflowFileLines", () => {
  it("says nothing while the file is applied and the writer looks", () => {
    expect(workflowFileLines(base)).toEqual([]);
  });
  it("names a refused file and the shape the board runs", () => {
    const [line] = workflowFileLines({ ...base, error: "cannot remove a column", error_at: "2026-11-14T10:00:00Z" });
    expect(line).toMatch(
      /^\.busyyaks\/workflow\.yml refused .* ago: cannot remove a column · board = last applied .* ago$/,
    );
  });
  it("calls the writer down once its last look is stale", () => {
    expect(workflowFileLines({ ...base, stale: true })).toEqual([
      expect.stringMatching(/^writer down · last look .* ago$/),
    ]);
  });
  it("a never-read file is its error, without a writer line", () => {
    const s = { ...base, applied_at: null, checked_at: null, stale: true, error: "the writer has not read it yet" };
    expect(workflowFileLines(s)).toEqual([".busyyaks/workflow.yml: the writer has not read it yet"]);
  });
});
