// Seeds the demo stack's acme/storefront board for the README screenshots, through the same doors a real board uses:
// the operator's JSON API (the first-run setup, the agent settings, Launch, labels, moves, a comment) and the agents'
// `kanban_*` MCP tools (create, ask, block, checklist, attach, handoff). The board starts as every board does (lead
// first): the operator Launches its lead, then its workers and a sub team under it — the real bin/launcher starts each
// as the stand-in agent (scripts/readme-images/agent). Synthetic content only. Run by scripts/readme-images/build;
// reads WEB, MCP and MCP_BOARD_TOKEN from the env; prints one JSON line: the cards the images open and the sessions launched.
"use strict";
const fs = require("fs");
const zlib = require("zlib");

const WEB = process.env.WEB;
const MCP = process.env.MCP;
const TOKEN = process.env.MCP_BOARD_TOKEN;
const SLUG = "acme/storefront";
if (!WEB || !MCP || !TOKEN) throw new Error("seed: WEB, MCP and MCP_BOARD_TOKEN are required");

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
  if (!cookie || !csrf) throw new Error("seed: no session cookie / CSRF token from the web app");
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

// the demo's one launcher: the stand-in agent (the demo's launch.commands allows exactly this invocation)
const LAUNCHER = {
  key: "readme",
  label: "demo agent",
  kind: "hermes",
  command: "readme-agent",
  args: [],
  via_shell: false,
};

// Settings → Agents & launchers: the current revision with LAUNCHER as every type's only launcher
async function demoLauncher() {
  const cur = await web("GET", "/api/settings/agents");
  const doc = cur.doc;
  doc.launchers = [LAUNCHER];
  for (const t of doc.agent_types) t.launchers = [LAUNCHER.key];
  await web("POST", "/api/settings/agents", { base: cur.revision.id, doc });
}

// the operator's Launch (POST /api/launch): bin/launcher starts the session; the board knows it by the answer's names
async function launch(type) {
  const out = await web("POST", "/api/launch", { slug: SLUG, type });
  return { session: out.session, agent: out.agent, type: out.type };
}

// A small PNG of an email layout (a header bar, a logo, order lines, a button), for the card's picture attachment:
// drawn here, so nothing outside these scripts is read. Rows of RGB, filtered 0, deflated (zlib), CRC per chunk.
function mockupPng(w = 480, h = 300) {
  const px = Buffer.alloc(h * (w * 3 + 1));
  const box = (x0, y0, x1, y1, [r, g, b]) => {
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) px.set([r, g, b], y * (w * 3 + 1) + 1 + x * 3);
  };
  box(0, 0, w, h, [244, 245, 247]);
  box(40, 20, w - 40, h - 20, [255, 255, 255]);
  box(40, 20, w - 40, 70, [15, 159, 143]);
  box(60, 34, 120, 56, [255, 255, 255]);
  for (let i = 0; i < 4; i++) {
    box(60, 96 + i * 30, 300 - i * 30, 108 + i * 30, [200, 204, 212]);
    box(w - 140, 96 + i * 30, w - 60, 108 + i * 30, [160, 166, 178]);
  }
  box(60, 230, 220, 262, [234, 88, 12]);
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(px)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

async function create(who, title, extra = {}) {
  const card = await tool("kanban_create", { project: SLUG, title, author: who.agent, column: "todo", ...extra });
  if (!Number.isInteger(card.id)) throw new Error(`seed: kanban_create answered no card id for ${title}`);
  return card.id;
}
const move = (id, who, transition) => tool("kanban_move", { id, author: who.agent, transition });
const label = (id, labels) => web("PATCH", `/api/cards/${id}`, { labels });

// the second board's shape: the engine's local-repo workflow (15 columns, review loops, three gates, Cancelled), mounted
// by build at /boards — the README's workflow graph
const WORKFLOW_SLUG = "acme/payments-api";
const WORKFLOW = "/boards/local_v4.board.json";

async function main() {
  await signIn();
  await web("POST", "/api/setup/complete"); // the first-run hello screen: the demo is set up
  const shape = JSON.parse(fs.readFileSync(WORKFLOW, "utf8"));
  await web("POST", `/api/projects/${WORKFLOW_SLUG}/workflow`, {
    columns: shape.columns,
    transitions: shape.transitions,
  });
  await demoLauncher();
  // lead first: the workers and the sub team run under it
  const LEAD = await launch("lead");
  const W1 = await launch("worker");
  const W2 = await launch("worker");
  const TEAM = await launch("team");
  // the collector's snapshot lists every session (every 5 s) before a card pings one: an unlisted session is gone
  const names = [LEAD, W1, W2, TEAM].map((s) => s.session);
  for (let i = 0; ; i++) {
    const listed = JSON.stringify(await web("GET", "/api/agents"));
    if (names.every((n) => listed.includes(`"name":"${n}"`))) break;
    if (i === 60) throw new Error(`seed: the agents snapshot never listed ${names.join(", ")}`);
    await new Promise((r) => setTimeout(r, 1000));
  }
  for (const [name, color] of [
    ["frontend", "blue"],
    ["backend", "purple"],
    ["security", "red"],
    ["perf", "orange"],
  ])
    await web("POST", `/api/projects/${SLUG}/labels`, { name, color });

  // Merged: done earlier
  for (const [title, labels] of [
    ["Upgrade to Ruby 3.4", ["backend"]],
    ["Fix currency rounding on invoices", ["backend"]],
  ]) {
    const id = await create(W1, title);
    await label(id, labels);
    await web("POST", `/api/cards/${id}/move`, { column: "merged" });
  }

  // Human Check: handed over with the PR, the CI build and how to check it
  const pager = await create(W1, "Paginate the product listing", {
    description: "The listing loads all 4,000 products at once. Page by 48, keep the filters in the URL.",
    priority: "high",
  });
  await label(pager, ["frontend", "perf"]);
  await move(pager, W1, "Start work");
  await tool("kanban_handoff", {
    id: pager,
    author: W1.agent,
    ui_change: false,
    pr_url: "https://github.com/acme/storefront/pull/42",
    ci_url: "https://ci.example.com/job/storefront/42/",
    qa: "Open /products: 48 per page, the page in the URL, filters kept when paging. p95 of /products 2.1 s → 180 ms.",
  });

  // QA
  const email = await create(W2, "Order confirmation email redesign", {
    description: "New layout from the design file: logo, order lines, delivery date, one CTA.",
  });
  await label(email, ["frontend"]);
  await move(email, W2, "Start work");
  await move(email, W2, "Send for QA");
  // the card face shows its newest picture: the new layout, attached by its agent
  await tool("kanban_attach", {
    id: email,
    author: W2.agent,
    filename: "email-layout.png",
    content_base64: mockupPng().toString("base64"),
    comment: "The new layout, rendered from the order fixtures.",
  });

  // In progress, with a checklist part done
  const search = await create(W1, "Typo-tolerant product search", {
    description: "`snekers` should find sneakers. Trigram index on the product name, rank exact matches first.",
    priority: "medium",
  });
  await label(search, ["backend"]);
  await move(search, W1, "Start work");
  const withList = await tool("kanban_checklist_add", {
    id: search,
    author: W1.agent,
    title: "Steps",
    items: [
      "Trigram index migration",
      "Ranking: exact > prefix > fuzzy",
      "Search box: show the corrected query",
      "Load test on 4,000 products",
    ],
  });
  const items = withList.checklists[0].items;
  if (items.length !== 4) throw new Error(`seed: the checklist came back with ${items.length} items, not 4`);
  for (const it of items.slice(0, 2))
    await tool("kanban_checklist_toggle", { item_id: it.id, done: true, author: W1.agent });
  await tool("kanban_comment", {
    id: search,
    author: W1.agent,
    body: "Index + ranking done on `card/31-typo-search`; 37 tests green. Next: the corrected query in the search box.",
  });
  await web("POST", `/api/cards/${search}/comment`, {
    body: "Show the corrected query only when nothing matched exactly.",
  });

  const cart = await create(W2, "Keep the cart across devices", { description: "Signed-in carts live server-side." });
  await label(cart, ["backend", "frontend"]);
  await move(cart, W2, "Start work");
  // blocked on the outside world, not on the operator
  await tool("kanban_block", {
    id: cart,
    author: W2.agent,
    reason: "the staging database upgrade",
    url: "https://status.example.com/incidents/118",
  });

  // a question for the operator: the lead asks, with choices (the card keeps its column, flagged as waiting)
  const pay = await create(LEAD, "Payment methods for EU customers", {
    description: "Card-only checkout loses EU orders. Decide which local methods ship first.",
    priority: "high",
  });
  await label(pay, ["backend"]);
  await move(pay, LEAD, "Start work");
  await tool("kanban_ask", {
    id: pay,
    author: LEAD.agent,
    question: "Which payment methods ship first? Each one is about two days of work plus a sandbox review.",
    options: ["SEPA debit only", "SEPA debit + iDEAL", "All four local methods"],
  });

  // To do + Backlog
  const coupon = await create(LEAD, "Rate-limit the coupon endpoint", { priority: "high" });
  await label(coupon, ["security"]);
  for (const [title, labels] of [
    ["Gift cards", ["frontend", "backend"]],
    ["Dark mode for the storefront", ["frontend"]],
  ]) {
    const id = await create(LEAD, title);
    await label(id, labels);
    await web("POST", `/api/cards/${id}/move`, { column: "backlog" });
  }
  // the sub team's card: its session stops on a permission dialog (its screen), which the board turns into a question
  const cdn = await create(TEAM, "Image CDN for product photos", { priority: "medium" });
  await label(cdn, ["perf"]);
  await move(cdn, TEAM, "Start work");
  await tool("kanban_comment", {
    id: cdn,
    author: TEAM.agent,
    body: "The CDN bucket needs a cache rule for /images before the switch; applying it.",
  });
  const sessions = [LEAD, W1, W2, TEAM].map((s) => s.session); // build gave each its screen before the launch
  console.log(JSON.stringify({ card: search, pager, pay, dialog: cdn, sessions }));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
