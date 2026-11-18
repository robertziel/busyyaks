// Captures the README screenshots from the demo stack (scripts/readme-images/demo-stack + build), all in the dark
// skin: busyyaks's own (Today, the board, a card, Today on a phone, a workflow graph) as they are, and the kanban module's with the
// module's part marked — the regions the engine renders (its root elements, measured in the page) keep their colours
// inside an accent outline labelled "kanban module"; the busyyaks host around them is dimmed and labelled "busyyaks host
// (dimmed)". The marking is drawn on the captured pixels in a canvas (a modal <dialog> sits in the browser's top
// layer, above any overlay the page could add), then encoded as WebP. Run by scripts/readme-images/build.
"use strict";

const { chromium } = require("playwright");
const fs = require("fs");

const WEB = process.env.WEB;
const OUT = { busyyaks: process.env.OUT_BUSYYAKS, module: process.env.OUT_MODULE }; // the WebP images, per README
const RAW = process.env.RAW; // the unmarked PNG captures + their text (for the private-term check), never committed
const CARD = Number(process.env.CARD);
if (!WEB || !OUT.busyyaks || !OUT.module || !RAW || !CARD)
  throw new Error("capture: WEB, OUT_BUSYYAKS, OUT_MODULE, RAW and CARD (the card to open) are required");
const BOARD = `${WEB}/projects/acme/storefront?tab=board`;
// the board running the engine's local-repo workflow (seed.js): the README's workflow graph
const WORKFLOW_BOARD = `${WEB}/projects/acme/payments-api?tab=board`;
// the stage's mode, named by build (never read off what is missing): BUSYYAKS_CARD = the README card's id on a stage
// made from a dump (demo-stack up … --from: busyyaks' README shots on the busyyaks board and that card), "" on the
// demo's own stage (the acme boards); unset, 0 or anything else → refused
if (process.env.BUSYYAKS_CARD === undefined || !/^([1-9]\d*)?$/.test(process.env.BUSYYAKS_CARD))
  throw new Error('capture: BUSYYAKS_CARD is required: the README card id on a dump stage, "" on the demo stage');
const BUSYYAKS_CARD = process.env.BUSYYAKS_CARD === "" ? null : Number(process.env.BUSYYAKS_CARD);
const OWN_BOARD = BUSYYAKS_CARD ? `${WEB}/projects/busyyaks?tab=board` : BOARD;
const OWN_CARD = BUSYYAKS_CARD ?? CARD;
const OWN_WORKFLOW = BUSYYAKS_CARD ? OWN_BOARD : WORKFLOW_BOARD;

const SCALE = 2;
const ACCENT = "#0F9F8F";
const QUALITY = 0.8;
const SKIN = "dark";
const DESKTOP = { width: 1440, height: 900 };
// the board: tall enough for the session lanes above it and the columns' cards under them
const BOARD_VIEW = { width: 1440, height: 1400 };
const openWorkflow = async (page) => {
  await page.getByRole("button", { name: "Workflow", exact: true }).click();
  await page.waitForSelector("dialog.kb-be[open] .kb-be-graph .kb-be-line", { state: "attached" }); // the laid-out graph's first arrow
};
// the card dialog's live line: its agent at work, with the phase its screen shows (polled every 3 s after the open)
const liveLine = (page) =>
  page.locator("dialog.kb-dialog[open] .kb-work-labels", { hasText: "thinking" }).waitFor({ timeout: 30000 });
// the page at rest: web fonts loaded, every finite animation / transition finished (an endless one — a live dot's
// pulse — never finishes, so it is not waited for), then two frames painted
// busyyaks' README card: its hand-off and, under it, its comment thread — its long description, its Terminals and its
// Attachments (the hand-off's pictures again) are folded away for this shot, so the thread is in the frame; the live
// line's poll answered (a failed one shows its error in the thread)
const FOLDED = ["Description", "Terminals", "Attachments"];
const toComments = async (page) => {
  await page.locator("dialog.kb-dialog[open] ol.kb-activity > li.c").first().waitFor();
  await page.locator("dialog.kb-dialog[open] .kb-live-err").waitFor({ state: "detached", timeout: 30000 });
  const missing = await page.evaluate((names) => {
    const heads = [...document.querySelectorAll("dialog.kb-dialog[open] section.kb-sec")].map((sec) => [
      sec,
      [...(sec.querySelector("h3")?.childNodes ?? [])]
        .filter((n) => n.nodeType === 3)
        .map((n) => n.nodeValue.trim())
        .join(""),
    ]);
    return names.filter((name) => {
      const hit = heads.find(([, t]) => t === name || t.startsWith(`${name} `));
      if (hit) hit[0].style.display = "none";
      return !hit;
    });
  }, FOLDED);
  if (missing.length) throw new Error(`capture: card: no ${missing.join(", ")} section to fold`);
};
// the board shot's session lanes as the seed set them, read off the page (the sidebar's /api/agents read, every 10 s;
// writing shows once a second read of its pane sees the ↓ count rise): each lane's count and each Working chip's own
// phase word, exactly. busyyaks' board (a dump stage, seed-busyyaks.js — the operator's ask): two need you, five working
// with a phase each, two quiet; the demo's acme board (seed.js): its lead and sub team blocked, a worker in review, one
// running a tool
const LANES = BUSYYAKS_CARD
  ? { you: 2, working: ["subagents", "thinking", "tool", "working", "writing"], quiet: 2 }
  : { you: 3, working: ["tool"], quiet: 0 };
const lanes = async (page) => {
  const want = JSON.stringify(LANES);
  let seen = "";
  for (let i = 0; i < 30; i++) {
    seen = await page.evaluate(() => {
      const count = (id) => Number(document.getElementById(id)?.querySelector("span")?.textContent ?? 0);
      const body = document.getElementById("lane-working")?.closest("section")?.querySelector(".lane-body");
      const words = [...(body?.querySelectorAll(".lane-work .lane-st-w") ?? [])].map((w) => w.textContent.trim());
      return JSON.stringify({ you: count("lane-you"), working: words.sort(), quiet: count("lane-quiet") });
    });
    if (seen === want) return;
    await page.waitForTimeout(2000);
  }
  throw new Error(`capture: board: the session lanes are ${seen}, the README shot wants ${want}`);
};
const settled = (page) =>
  page.evaluate(async () => {
    await document.fonts.ready;
    const finite = document.getAnimations().filter((a) => a.effect?.getComputedTiming().iterations !== Infinity);
    await Promise.all(finite.map((a) => a.finished));
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  });

// Each image: which README it is for, its page, the element that says the page has loaded, what to do before the
// capture, and — for the module's — its root elements with one label each, and an optional crop (CSS px, or around
// the module's first element with a margin of dimmed host).
const SHOTS = [
  { readme: "busyyaks", name: "today", url: `${WEB}/`, ready: ".heatmap", viewport: DESKTOP },
  {
    readme: "busyyaks",
    name: "board",
    url: OWN_BOARD,
    ready: ".kb-board .kb-card",
    viewport: BOARD_VIEW,
    before: lanes,
  },
  {
    readme: "busyyaks",
    name: "card",
    url: `${OWN_BOARD}&card=${OWN_CARD}`,
    ready: "dialog.kb-dialog[open]",
    viewport: BUSYYAKS_CARD ? { width: 1440, height: 1300 } : DESKTOP,
    // the demo's card has its agent at work (the live line); busyyaks' README card is finished: its comment thread
    before: BUSYYAKS_CARD ? toComments : liveLine,
  },
  {
    readme: "busyyaks",
    name: "today-mobile",
    url: `${WEB}/`,
    ready: ".heatmap",
    viewport: { width: 390, height: 844 },
  },
  {
    readme: "busyyaks",
    name: "workflow",
    url: OWN_WORKFLOW,
    ready: ".kb-board",
    viewport: { width: 1440, height: 2500 }, // tall: the whole graph (15 columns, top to bottom) at its reading size
    before: openWorkflow,
    cropTo: "dialog.kb-be[open]",
    cropAround: 0,
  },
  {
    readme: "module",
    name: "board",
    url: BOARD,
    ready: ".kb-board .kb-card",
    viewport: DESKTOP,
    module: [".ak-launchbar", ".kb-board"],
    labels: ["kanban module · launch bar", "kanban module · board"],
  },
  {
    readme: "module",
    name: "card",
    url: `${BOARD}&card=${CARD}`,
    ready: "dialog.kb-dialog[open]",
    // wider than the others: the dialog keeps its width, so the host's label fits beside it
    viewport: { width: 1600, height: 1000 },
    before: liveLine,
    module: ["dialog.kb-dialog[open]"],
    labels: ["kanban module · card dialog"],
  },
  {
    readme: "module",
    name: "launch-bar",
    url: BOARD,
    ready: ".kb-board .kb-card",
    viewport: DESKTOP,
    module: [".ak-launchbar"],
    labels: ["kanban module · launch bar"],
    clip: { x: 0, y: 0, width: 1440, height: 400 },
  },
  {
    readme: "module",
    name: "workflow-editor",
    url: BOARD,
    ready: ".kb-board .kb-card",
    viewport: DESKTOP,
    before: openWorkflow,
    module: ["dialog.kb-be[open]"],
    labels: ["kanban module · workflow editor"],
    cropAround: 72,
  },
];

// the marking, run in a blank page: the capture → canvas → dim the host, outline + label the module → WebP data URL
function annotate({ png, rects, scale, accent, labels, quality, dark }) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onerror = () => reject(new Error("capture: the screenshot did not decode"));
    img.onload = () => {
      const c = document.createElement("canvas");
      c.width = img.width;
      c.height = img.height;
      const g = c.getContext("2d");
      g.drawImage(img, 0, 0);
      if (rects.length === 0) return resolve(c.toDataURL("image/webp", quality)); // busyyaks's own: as captured
      const pad = 6 * scale;
      const box = rects.map((r) => ({
        x: r.x * scale - pad,
        y: r.y * scale - pad,
        w: r.width * scale + 2 * pad,
        h: r.height * scale + 2 * pad,
      }));
      const round = (p, b, rad) => p.roundRect(b.x, b.y, b.w, b.h, rad);
      // the host, dimmed: everything outside the module's boxes
      const dim = new Path2D();
      dim.rect(0, 0, c.width, c.height);
      box.forEach((b) => round(dim, b, 12 * scale));
      // washed out towards the skin's background: the host recedes, the module keeps its colours
      g.fillStyle = dark ? "rgba(17, 18, 22, 0.74)" : "rgba(244, 245, 247, 0.74)";
      g.fill(dim, "evenodd");
      // the module: an outline per box
      g.lineWidth = 3 * scale;
      g.strokeStyle = accent;
      box.forEach((b) => {
        const p = new Path2D();
        round(p, b, 12 * scale);
        g.stroke(p);
      });
      const chip = (text, x, y, bg, fg, border) => {
        g.font = `600 ${14 * scale}px Inter, "Segoe UI", system-ui, sans-serif`;
        const w = g.measureText(text).width + 20 * scale;
        const h = 26 * scale;
        const cx = Math.min(Math.max(x, 4 * scale), c.width - w - 4 * scale);
        const cy = Math.min(Math.max(y, 4 * scale), c.height - h - 4 * scale);
        g.fillStyle = bg;
        g.beginPath();
        g.roundRect(cx, cy, w, h, 7 * scale);
        g.fill();
        if (border) {
          g.lineWidth = 1.5 * scale;
          g.strokeStyle = border;
          g.stroke();
        }
        g.fillStyle = fg;
        g.textBaseline = "middle";
        g.fillText(text, cx + 10 * scale, cy + h / 2 + scale);
        return { x: cx, y: cy, w, h };
      };
      const width = (text) => {
        g.font = `600 ${14 * scale}px Inter, "Segoe UI", system-ui, sans-serif`;
        return g.measureText(text).width + 20 * scale;
      };
      // each box's label rests on its outline's top edge, right-aligned: it reaches into the outline's padding only,
      // never the module's content; the host's in the top-right corner of the image
      box.forEach((b, i) =>
        chip(labels[i], b.x + b.w - width(labels[i]) - 40 * scale, b.y - 22 * scale, accent, "#FFFFFF"),
      );
      const hostText = "busyyaks host (dimmed)";
      chip(hostText, c.width - width(hostText) - 12 * scale, 12 * scale, "#FFFFFF", "#4B5563", "#9CA3AF");
      resolve(c.toDataURL("image/webp", quality));
    };
    img.src = `data:image/png;base64,${png}`;
  });
}

// the crop around the module's first element (or `cropTo`): its box plus `cropAround` CSS px of host on every side, in
// the viewport
async function around(page, shot) {
  const sel = shot.cropTo ?? shot.module[0];
  const r = await page.locator(sel).boundingBox();
  if (!r) throw new Error(`capture: ${shot.name}: ${sel} has no box`);
  const m = shot.cropAround;
  const x = Math.max(0, Math.floor(r.x - m));
  const y = Math.max(0, Math.floor(r.y - m));
  return {
    x,
    y,
    width: Math.min(shot.viewport.width, Math.ceil(r.x + r.width + m)) - x,
    height: Math.min(shot.viewport.height, Math.ceil(r.y + r.height + m)) - y,
  };
}

async function main() {
  const browser = await chromium.launch();
  try {
    for (const shot of SHOTS) {
      const regions = shot.module ?? [];
      const labels = shot.labels ?? [];
      if (labels.length !== regions.length) throw new Error(`capture: ${shot.name}: one label per element`);
      const ctx = await browser.newContext({ viewport: shot.viewport, deviceScaleFactor: SCALE });
      await ctx.addInitScript((skin) => localStorage.setItem("busyyaks.skin", skin), SKIN);
      const page = await ctx.newPage();
      await page.goto(shot.url, { waitUntil: "networkidle" });
      await page.waitForSelector(shot.ready);
      if (shot.before) await shot.before(page);
      await settled(page);
      const clip =
        shot.clip ?? (shot.cropAround !== undefined ? await around(page, shot) : { x: 0, y: 0, ...shot.viewport });
      const rects = await page.evaluate(
        ({ sels, clip }) =>
          sels.map((sel) => {
            const el = document.querySelector(sel);
            if (!el) throw new Error(`capture: no element ${sel}`);
            const r = el.getBoundingClientRect();
            const x = Math.max(r.x, clip.x);
            const y = Math.max(r.y, clip.y);
            const right = Math.min(r.right, clip.x + clip.width);
            const bottom = Math.min(r.bottom, clip.y + clip.height);
            return { x: x - clip.x, y: y - clip.y, width: right - x, height: bottom - y };
          }),
        { sels: regions, clip },
      );
      // every word the capture shows, for the private-term check (scripts/readme-images/build): the rendered text, the
      // open dialogs' (top layer), and what form fields show — their values and placeholders (innerText has neither)
      const text = await page.evaluate(() =>
        [
          document.body.innerText,
          ...[...document.querySelectorAll("dialog[open]")].map((d) => d.innerText),
          ...[...document.querySelectorAll("input, textarea, select")].flatMap((f) => [f.value, f.placeholder ?? ""]),
        ].join("\n"),
      );
      const id = `${shot.readme}-${shot.name}`;
      const marks = regions.length ? `${labels.join("\n")}\nbusyyaks host (dimmed)\n` : "";
      fs.writeFileSync(`${RAW}/${id}.txt`, `${text}\n${marks}`);
      const png = (await page.screenshot({ clip })).toString("base64");
      const blank = await ctx.newPage();
      const url = await blank.evaluate(annotate, {
        png,
        rects,
        scale: SCALE,
        accent: ACCENT,
        labels,
        quality: QUALITY,
        dark: SKIN === "dark",
      });
      const file = `${OUT[shot.readme]}/${shot.name}.webp`;
      fs.writeFileSync(file, Buffer.from(url.split(",")[1], "base64"));
      fs.writeFileSync(`${RAW}/${id}.png`, Buffer.from(png, "base64"));
      console.log(`${shot.readme} ${shot.name}.webp ${fs.statSync(file).size} bytes`);
      await ctx.close();
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
