// The README screenshot environment, after the dump is loaded (load-dump.rb): busyyaks' own board as it was, plus the
// elements a quiet day does not show — added through the same doors a real board uses (the operator's JSON API, the
// agents' kanban_* MCP tools). The board starts as every board does: the operator Launches its lead (which
// adopts the dump's ownerless cards), then workers and a sub team under it, each the stand-in agent
// (scripts/readme-images/agent) drawing the screen build gave it: the session lanes show two that need you (the lead's
// question, the sub team's dialog), five working (thinking · tool · writing · subagents · working) and two idle.
// Added: labels on the cards, a question with options,
// a session dialog (the sub team's permission prompt), a checklist part done, due dates (one overdue), a sub-card, a
// cover, the review loop's `unresolved` label, a short review thread on the README card, and a daily report. Every word
// written here is synthetic. Run by scripts/readme-images/build; env WEB, MCP, MCP_BOARD_TOKEN, CARD (the README card);
// prints one JSON line: the sessions launched and the card whose dialog becomes a question.
"use strict";

const WEB = process.env.WEB;
const MCP = process.env.MCP;
const TOKEN = process.env.MCP_BOARD_TOKEN;
const CARD = Number(process.env.CARD);
const SLUG = "busyyaks";
if (!WEB || !MCP || !TOKEN || !CARD) throw new Error("seed-busyyaks: WEB, MCP, MCP_BOARD_TOKEN and CARD are required");

let rpcId = 0;
async function tool(name, args) {
  const res = await fetch(MCP, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method: "tools/call", params: { name, arguments: args } }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${name}: ${body.error.message}`);
  const text = body.result.content[0].text;
  if (body.result.isError) throw new Error(`${name}: ${text}`);
  return JSON.parse(text);
}

let cookie = "";
let csrf = "";
async function signIn() {
  const res = await fetch(`${WEB}/projects/${SLUG}`);
  cookie = (res.headers.get("set-cookie") ?? "").split(";")[0];
  csrf = (await res.text()).match(/name="csrf-token" content="([^"]+)"/)?.[1] ?? "";
  if (!cookie || !csrf) throw new Error("seed-busyyaks: no session cookie / CSRF token from the web app");
}
async function web(method, path, body) {
  const res = await fetch(`${WEB}${path}`, {
    method,
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf, Cookie: cookie, Origin: WEB },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${JSON.stringify(json)}`);
  return json;
}
const launch = async (type) => {
  const out = await web("POST", "/api/launch", { slug: SLUG, type });
  return { session: out.session, agent: out.agent };
};

// the board's cards by column, as the board answers them
async function cards() {
  const b = await web("GET", `/api/projects/${SLUG}/board`);
  return Object.fromEntries(b.columns.map((c) => [c.column, c.cards]));
}
// the first card of the first of these columns that holds one (the dumped board is whatever the live one was), never
// one already taken nor one flagged (a worker on a flagged card would need you, not work); none → refused, naming the
// columns
const first = (cols, keys, why, taken = []) => {
  for (const key of keys) {
    const c = (cols[key] ?? []).find((x) => !taken.includes(x.id) && !x.needs_operator && !x.blocked);
    if (c) return c;
  }
  throw new Error(`seed-busyyaks: no card in ${keys.join(", ")} for ${why} (the dump's board has none there)`);
};
// a worker's card: work in flight first, then the queue, then the backlog — never a gate (its owner waits for you)
const WORK = ["doing", "local_author", "local_agent_review", "public_author", "public_agent_review", "todo", "backlog"];

// a card's labels from its title's words: the board's areas
const AREAS = [
  ["frontend", "blue", /\b(page|widget|sidebar|board|dialog|skin|card face|ui|header|today|launch bar|terminal)\b/i],
  ["backend", "purple", /\b(scanner|poller|webhook|database|api|launcher|collector|notifier|mcp)\b/i],
  ["engine", "green", /\b(engine|workflow|kanban|review loop|gate)\b/i],
  ["ci", "orange", /\b(ci|jenkins|tests?|lint|flaky)\b/i],
  ["docs", "yellow", /\b(readme|docs?|screenshots?)\b/i],
];

async function main() {
  await signIn();
  // the launch order names the sessions (build's BUSYYAKS_SESSIONS gives each its screen)
  const LEAD = await launch("lead");
  const W1 = await launch("worker"); // thinking
  const W2 = await launch("worker"); // a running tool
  const TEAM = await launch("team"); // a permission dialog
  const MORE = [];
  for (let i = 0; i < 5; i++) MORE.push(await launch("worker")); // writing · subagents · working · idle · idle (no card)
  const WORKING = [W1, W2, ...MORE.slice(0, 3)];
  const names = [LEAD, W1, W2, TEAM, ...MORE].map((s) => s.session);
  for (let i = 0; ; i++) {
    const listed = JSON.stringify(await web("GET", "/api/agents"));
    if (names.every((n) => listed.includes(`"name":"${n}"`))) break;
    if (i === 60) throw new Error(`seed-busyyaks: the agents snapshot never listed ${names.join(", ")}`);
    await new Promise((r) => setTimeout(r, 1000));
  }

  const have = new Set((await web("GET", `/api/projects/${SLUG}/board`)).labels.map((l) => l.name));
  for (const [name, color] of [...AREAS.map(([n, c]) => [n, c]), ["unresolved", "red"]])
    if (!have.has(name)) await web("POST", `/api/projects/${SLUG}/labels`, { name, color });
  let cols = await cards();
  for (const list of Object.values(cols))
    for (const c of list) {
      const labels = AREAS.filter(([, , re]) => re.test(c.title)).map(([n]) => n);
      if (labels.length)
        await web("PATCH", `/api/cards/${c.id}`, { labels: [...new Set([...(c.labels ?? []), ...labels])] });
    }

  // the five working sessions take the work in flight, one card each
  const taken = [];
  for (const w of WORKING) {
    const c = first(cols, WORK, `${w.session}'s card`, taken);
    taken.push(c.id);
    await tool("kanban_claim", { id: c.id, assignee: w.agent, tmux_session: w.session });
  }
  const doing = { id: taken[0] };

  // a checklist part done, and a sub-card under it
  const list = await tool("kanban_checklist_add", {
    id: doing.id,
    author: W1.agent,
    title: "Steps",
    items: ["Dump the board", "Load it into the stage", "Seed what a quiet day lacks", "Capture the five shots"],
  });
  for (const it of list.checklists[0].items.slice(0, 2))
    await tool("kanban_checklist_toggle", { item_id: it.id, done: true, author: W1.agent });
  await tool("kanban_create", {
    project: SLUG,
    title: "Card shot: show the comment thread under the hand-off",
    author: W1.agent,
    tmux_session: W1.session,
    column: "todo",
    parent: doing.id,
  });

  // the lead's question for the operator, with choices, on a card it adopted (the card keeps its column, flagged as
  // waiting): the lead is the second session that needs you
  cols = await cards();
  const asked = Object.values(cols)
    .flat()
    .find((c) => c.assignee === LEAD.agent && !c.needs_operator && !taken.includes(c.id));
  if (!asked) throw new Error(`seed-busyyaks: the lead ${LEAD.session} adopted no card to ask on`);
  await tool("kanban_ask", {
    id: asked.id,
    author: LEAD.agent,
    tmux_session: LEAD.session,
    question: "The projects dir in setup: typed as a path, or picked in a folder browser of the host?",
    options: ["Type the path", "Pick a folder", "Both"],
  });
  // the review loop at its limit: the label the handoff adds
  const loop = [...(cols.local_agent_review ?? []), ...(cols.local_human_review ?? [])].find(
    (c) => !taken.includes(c.id) && c.id !== asked.id,
  );
  if (loop)
    await web("PATCH", `/api/cards/${loop.id}`, { labels: [...new Set([...(loop.labels ?? []), "unresolved"])] });

  // due dates (one overdue) and a cover colour on the backlog
  const todo = first(cols, ["todo", "backlog"], "a due date", [...taken, asked.id]);
  const day = 86400 * 1000;
  await web("PATCH", `/api/cards/${todo.id}`, { due: new Date(Date.now() + 2 * day).toISOString().slice(0, 19) + "Z" });
  const [b1, b2] = (cols.backlog ?? []).filter((c) => ![todo.id, ...taken].includes(c.id));
  if (!b1 || !b2) throw new Error("seed-busyyaks: the dump's backlog has fewer than 2 cards");
  await web("PATCH", `/api/cards/${b1.id}`, { due: new Date(Date.now() - day).toISOString().slice(0, 19) + "Z" });
  await web("PATCH", `/api/cards/${b2.id}`, { cover: "purple" });

  // the sub team's card: its session stops on a permission dialog, which the board turns into a question
  const dialog = await tool("kanban_create", {
    project: SLUG,
    title: "Re-pin the vendored engine after the miniature change",
    author: TEAM.agent,
    tmux_session: TEAM.session,
    column: "todo",
    priority: "medium",
  });
  await tool("kanban_move", { id: dialog.id, author: TEAM.agent, transition: "Start work" });
  await tool("kanban_comment", {
    id: dialog.id,
    author: TEAM.agent,
    body: "The pin script needs the engine checkout path; running it with the operator's checkout.",
  });

  // the README card: its lead listens on it (no "nobody is listening"), and a short review thread under its hand-off
  await web("POST", `/api/cards/${CARD}/owner`, { session: LEAD.session });
  const readme = await web("GET", `/api/cards/${CARD}`);
  const author = readme.card.assignee;
  if (!author) throw new Error(`seed-busyyaks: card ${CARD} has no assignee to write its thread`);
  const say = (who, body) => tool("kanban_comment", { id: CARD, author: who, body });
  await say(
    `reviewer-${author}`,
    "[Reviewer Agent] · OPEN · round 1 · severity: major · category: correctness\n\nAn approved gate card is " +
      "counted under **to review**, but it waits for its agent, not for you. Count it under **approved** and leave " +
      "it out of the badge.",
  );
  await say(
    author,
    "[Author Agent] · FIXED · round 1 — approved gate cards move to the approved segment; the badge counts to " +
      "answer + to review only. +3 vitest cases.",
  );
  await say(
    `qa-${author}`,
    "[QA Agent] · PASS · round 2\n\n| check | result |\n|---|---|\n| frontend stage | exit 0 · 58 files |\n" +
      "| desktop + phone | screenshots attached |\n| keyboard | Tab reaches every segment, Enter opens its tab |",
  );
  await web("POST", `/api/cards/${CARD}/comment`, { body: "One glance says what needs me. Ship it." });

  await tool("post_report", {
    title: "Daily report",
    author: "daily-report",
    body_markdown:
      "## Needs you\n\n- card #" +
      asked.id +
      ": the projects dir in setup — a question with 3 options\n\n## Shipped\n\n- The waiting widget counts each " +
      "kind on its own\n- Dark is the default skin\n\n## At risk\n\n- Two public PRs wait on CI\n",
  });
  console.log(JSON.stringify({ sessions: names, dialog: dialog.id }));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
