// The scripted model of the board end to end (board-e2e). Real Hermes sessions call the real busyyaks MCP
// tools; this file only decides the next turn from the marker words in the session's newest user line. A turn the script
// does not know answers a marker, never a normal reply, so the step waiting for it fails.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { LLMock } from "/usr/local/lib/node_modules/@copilotkit/aimock/dist/index.js";

const dir = process.argv[2];
const WORDS = /^(E2E_LEAD|E2E_WORKER|E2E_OP_COMMENT|E2E_OP_SECOND|E2E_ANSWER|E2E_RACE_TURN)$/;
const textOf = (c) => (typeof c === "string" ? c : (c ?? []).map((p) => p.text ?? "").join("\n"));
const log = (row) => appendFileSync(join(dir, "turns.jsonl"), `${JSON.stringify(row)}\n`);
const kanban = (tool) => `mcp__busyyaks__kanban_${tool}`;
const queues = {};
const done = new Set();
let calls = 0;

function plan(role, word, me) {
  const id = Number(readFileSync(join(dir, "card"), "utf8"));
  const author = me.agent;
  if (role === "lead")
    return word === "E2E_LEAD" ? [[kanban("spawn"), { id, type: "worker", tmux_session: me.session, author }]] : [];
  if (role !== "worker") return [];
  if (word === "E2E_WORKER")
    return [
      [kanban("move"), { id, author, transition: "Start work" }],
      [kanban("comment"), { id, author, body: "E2E_W1 worker started" }],
    ];
  if (word === "E2E_OP_COMMENT")
    return [
      [kanban("comment"), { id, author, body: "E2E_W2 heard the comment" }],
      ["HOLD", {}],
    ];
  if (word === "E2E_OP_SECOND")
    return [
      [
        kanban("ask"),
        { id, author, tmux_session: me.session, question: "E2E_W3 which one?", options: ["red", "blue"] },
      ],
    ];
  // a dialog that opens between a ping's paste and its Enter: held until the driver has pasted
  if (word === "E2E_RACE_TURN")
    return [
      ["HOLD_THEN", {}],
      ["terminal", { command: `rm -rf ${dir}/race-target && touch ${dir}/race-ran` }],
    ];
  if (word === "E2E_ANSWER")
    return [
      ["terminal", { command: `rm -rf ${dir}/deny-target && touch ${dir}/denied-ran` }],
      ["terminal", { command: `rm -rf ${dir}/allow-target && sleep 3 && touch ${dir}/shell-ran` }],
      [
        kanban("handoff"),
        {
          id,
          author,
          column: "human_check",
          ui_change: false,
          pr_url: "https://github.com/e2e/demo/pull/1",
          qa: "E2E_W5 checked: comment, ask, answer and two approvals on a real Hermes session; see the run's step log.",
        },
      ],
    ];
  return [];
}

async function turn(req) {
  const tools = req.tools ?? [];
  const messages = req.messages;
  const all = messages.map((m) => textOf(m.content)).join("\n");
  if (!tools.length) return { content: "e2e title" };
  const role = all.includes("E2E_WORKER") ? "worker" : all.includes("E2E_LEAD") ? "lead" : "other";
  const me = { session: all.match(/session=(\S+)/)?.[1], agent: all.match(/agent=(\S+)/)?.[1] };
  const last = messages.at(-1);
  if (last.role === "tool") log({ role, result: textOf(last.content).slice(-400) });
  else {
    const words = textOf(last.content).match(/E2E_[A-Z0-9_]+/g) ?? [];
    const fresh = words.filter((w) => WORDS.test(w) && !done.has(w));
    log({ role, user: words, fresh, history_has_slow_answer: all.includes("E2E_SLOW_ANSWER_KEPT") });
    queues[role] = [];
    for (const w of fresh) {
      done.add(w);
      queues[role].push(...plan(role, w, me));
    }
  }
  let next = (queues[role] ?? []).shift();
  if (next?.[0] === "HOLD_THEN") {
    writeFileSync(join(dir, "race-holding"), "1");
    while (!existsSync(join(dir, "race-release"))) await sleep(50);
    next = queues[role].shift();
  }
  if (!next) return { content: `E2E_${role.toUpperCase()}_TURN_DONE` };
  if (next[0] === "HOLD") {
    writeFileSync(join(dir, "holding"), "1");
    while (!existsSync(join(dir, "release"))) await sleep(50);
    return { content: "E2E_SLOW_ANSWER_KEPT" };
  }
  if (!tools.some((t) => t.function.name === next[0])) return { content: `E2E_NO_TOOL_${next[0]}` };
  log({ role, call: next[0] });
  return { toolCalls: [{ id: `call_e2e_${++calls}`, name: next[0], arguments: JSON.stringify(next[1]) }] };
}

// its port: chosen free by board-e2e at run time, required
const port = Number(process.env.BOARD_E2E_MODEL_PORT);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("BOARD_E2E_MODEL_PORT: a port 1-65535 is required");
const mock = new LLMock({ host: "127.0.0.1", port, logLevel: "warn" });
mock.addFixture({
  match: { predicate: () => true },
  response: async (req) => {
    try {
      return await turn(req);
    } catch (e) {
      log({ error: String(e?.stack ?? e) });
      throw e;
    }
  },
});
await mock.start();
writeFileSync(join(dir, "up"), "1");
