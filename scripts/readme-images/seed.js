// Seeds the demo stack's acme/storefront board for the README screenshots, through the same doors a real board uses:
// the agents' `kanban_*` MCP tools (register, create, ask, checklist, handoff) and the operator's JSON API (labels,
// moves). Synthetic content only. Run by scripts/readme-images/build; reads WEB, MCP and MCP_TOKEN from the env.
"use strict";

const WEB = process.env.WEB;
const MCP = process.env.MCP;
const TOKEN = process.env.MCP_TOKEN;
const SLUG = "acme/storefront";
if (!WEB || !MCP || !TOKEN) throw new Error("seed: WEB, MCP and MCP_TOKEN are required");

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
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf, Cookie: cookie },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${JSON.stringify(json)}`);
  return json;
}

const LEAD = { session: "acme_storefront_teamlead", agent: "claude-acme_storefront_teamlead", type: "lead" };
const W1 = { session: "acme_storefront_worker", agent: "worker-acme_storefront_worker", type: "worker" };
const W2 = { session: "acme_storefront_worker_2", agent: "worker-acme_storefront_worker_2", type: "worker" };
const TEAM = { session: "acme_storefront_team", agent: "team-acme_storefront_team", type: "team" };

async function create(who, title, extra = {}) {
  const card = await tool("kanban_create", { project: SLUG, title, author: who.agent, column: "todo", ...extra });
  if (!Number.isInteger(card.id)) throw new Error(`seed: kanban_create answered no card id for ${title}`);
  return card.id;
}
const move = (id, who, transition) => tool("kanban_move", { id, author: who.agent, transition });
const label = (id, labels) => web("PATCH", `/api/cards/${id}`, { labels });

async function main() {
  await signIn();
  for (const s of [LEAD, W1, W2, TEAM])
    await tool("kanban_register", { project: SLUG, type: s.type, tmux_session: s.session, author: s.agent });
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

  const cart = await create(W2, "Keep the cart across devices", { description: "Signed-in carts live server-side." });
  await label(cart, ["backend", "frontend"]);
  await move(cart, W2, "Start work");

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
    ["Image CDN for product photos", ["perf"]],
  ]) {
    const id = await create(TEAM, title);
    await label(id, labels);
    await web("POST", `/api/cards/${id}/move`, { column: "backlog" });
  }
  console.log(JSON.stringify({ card: search, pager, pay }));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
