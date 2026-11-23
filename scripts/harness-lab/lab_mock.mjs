// The scripted model + MCP server the real agent CLIs talk to in the harness contract. aimock speaks the
// wire formats; this file is only the script. The last LAB_* word the user typed picks the turn: LAB_SLOW holds it
// until <dir>/release exists, LAB_MCP calls the MCP tool, LAB_SHELL calls the harness's shell tool, anything else
// answers. A tool result answers LAB_DONE. Every request is one line of <dir>/requests.jsonl. A request the script does
// not know gets a LAB_NO_* marker, never a normal answer, so the step that waited for one fails.
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { LLMock, MCPMock } from "/usr/local/lib/node_modules/@copilotkit/aimock/dist/index.js";

const [dir, portFile] = process.argv.slice(2);
const SHELLS = { Bash: "command", terminal: "command", shell: "command", exec_command: "cmd" };
// the CLIs' own session-title calls, the only requests that carry no tools (Hermes, Codex)
const TITLE_CALLS = /You name chat sessions|single-line task title/;
const PLAIN_WORDS = new Set(["LAB_HELLO", "LAB_PING"]);
const seen = new Set();
let calls = 0;

const record = (row) => appendFileSync(join(dir, "requests.jsonl"), `${JSON.stringify(row)}\n`);
const textOf = (content) =>
  typeof content === "string" ? content : (content ?? []).map((part) => part.text ?? "").join("\n");
const call = (tool, args) => ({
  toolCalls: [
    {
      id: `call_lab_${++calls}`,
      name: tool.function.name,
      arguments: JSON.stringify(args),
      ...(tool.namespace ? { namespace: tool.namespace } : {}),
    },
  ],
});

function mcpTurn(tools) {
  const tool = tools.find((t) => t.function.name.includes("lab_echo"));
  return tool ? call(tool, { text: "from-model" }) : { content: "LAB_NO_MCP_TOOL" };
}

function shellTurn(tools) {
  const tool = tools.find((t) => SHELLS[t.function.name]);
  if (!tool) return { content: "LAB_NO_SHELL_TOOL" };
  // rm -rf: Hermes asks only before a command it calls dangerous
  const command = `rm -rf ${join(dir, "lab-target")} && touch ${join(dir, "shell-ran")}`;
  const args = { [SHELLS[tool.function.name]]: command };
  if (tool.function.name === "exec_command")
    Object.assign(args, { sandbox_permissions: "require_escalated", justification: "lab" });
  return call(tool, args);
}

async function slowTurn() {
  writeFileSync(join(dir, "holding"), "1");
  while (!existsSync(join(dir, "release"))) await sleep(50);
  return { content: "LAB_SLOW_DONE" };
}

async function turn(req) {
  const tools = req.tools ?? [];
  const messages = req.messages;
  const all = messages.map((m) => textOf(m.content)).join("\n");
  if (tools.length === 0) {
    const title = TITLE_CALLS.test(all);
    record({ side: title ? "title" : "no_tools" });
    return { content: title ? "lab title" : "LAB_NO_TOOLS" };
  }

  const last = messages.at(-1);
  const word =
    textOf(messages.findLast((m) => m.role === "user")?.content)
      .match(/LAB_[A-Z]+/g)
      ?.at(-1) ?? "";
  // Claude Code folds a turn's tool results and its user text together: a result ends only a word already answered
  const ranTool = last.role === "tool" || (messages.at(-2)?.role === "tool" && seen.has(word));
  record({
    text: word,
    tool_result: ranTool,
    tools: tools.length,
    history_has_slow_answer: JSON.stringify(messages).includes("LAB_SLOW_DONE"),
  });
  if (ranTool) return { content: "LAB_DONE" };

  seen.add(word);
  if (word === "LAB_SLOW") return slowTurn();
  if (word === "LAB_MCP") return mcpTurn(tools);
  if (word === "LAB_SHELL") return shellTurn(tools);
  return { content: PLAIN_WORDS.has(word) ? "LAB_REPLY" : "LAB_NO_WORD" };
}

async function recordedTurn(req) {
  try {
    return await turn(req);
  } catch (e) {
    record({ error: String(e?.stack ?? e) });
    throw e;
  }
}

const mcp = new MCPMock({ serverInfo: { name: "lab", version: "1" } });
mcp.addTool({
  name: "lab_echo",
  description: "echo",
  inputSchema: { type: "object", properties: { text: { type: "string" } } },
});
mcp.onToolCall("lab_echo", () => {
  record({ mcp: "tools/call", tool: "lab_echo" });
  return "echoed";
});

const mock = new LLMock({ host: "127.0.0.1", port: 0, logLevel: "warn", responsesTools: "extended" });
mock.mount("/mcp", mcp);
mock.addFixture({ match: { predicate: () => true }, response: recordedTurn });
const url = await mock.start();
writeFileSync(portFile, new URL(url).port);
