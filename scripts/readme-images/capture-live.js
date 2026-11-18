// The README screenshots, captured from the operator's own LIVE local dashboard (scripts/readme-images/live): busyyaks'
// real board, a real busyyaks card and its real workflow, in the dark skin — with everything that is not busyyaks
// renamed before each screenshot by the rule in rename.js (applied to every /api answer and to the rendered page), and
// every image refused when the gate (`leaks`) finds a private term, an email, a host, a person's name or a real
// project name in what the page shows (its text and its attributes). Nothing but the images leaves this run: the
// names it read stay in memory; RAW gets the renamed text (for QA) and the gate's verdict.
//
// Env: WEB (http://127.0.0.1:<port>), COOKIE_FILE (rack.session=…, bin/qa-cookie's output), OWN (busyyaks' project slug on the
// dashboard), KEEP (the other projects shown as they are, space-separated slugs; empty = none), CARD (a busyyaks card to open), TERMS (a file: one term per line, # comments — the private-term lists +
// what live passes: the public host), NAMES (a file: the operator's name and each of its words), OWN_REPOS (busyyaks' public
// owner/repo names, space-separated: kept; every other owner/repo is renamed), OUT, RAW. Only 127.0.0.1 is ever requested: every other
// request (pictures of people, fonts from elsewhere, analytics) is aborted.
"use strict";

const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const { makeRenamer, leaks } = require("./rename.js");
const { liveSpec } = require("./live-spec.js");
const { samplePicture } = require("./samples.js");

const { WEB, COOKIE_FILE, OWN, KEEP, OUT, RAW, TERMS, NAMES, OWN_REPOS } = process.env;
const COOKIE = COOKIE_FILE && fs.readFileSync(COOKIE_FILE, "utf8").trim();
const CARD = Number(process.env.CARD);
if (!WEB || !COOKIE || !OWN || KEEP === undefined || !OUT || !RAW || !TERMS || !NAMES || !CARD || !OWN_REPOS)
  throw new Error("capture-live: WEB, COOKIE_FILE, OWN, KEEP, CARD, TERMS, NAMES, OWN_REPOS, OUT and RAW are required");
const ORIGIN = new URL(WEB);
const SCALE = 2;
const QUALITY = 0.8;
const SKIN = "dark";
const DESKTOP = { width: 1440, height: 900 };
const BOARD = `${WEB}/projects/${OWN}?tab=board`;
// the rule's input, read now from the live dashboard (live-spec.js: specFrom refuses an empty term list, mergedRepos a
// Today answer without its merged_prs)
const readSpec = async () =>
  (
    await liveSpec({
      web: WEB,
      cookie: COOKIE,
      own: OWN,
      keep: KEEP,
      ownRepos: OWN_REPOS,
      termsFile: TERMS,
      namesFile: NAMES,
      who: "capture-live",
    })
  ).spec;

// in the page: the same rule on every text node and attribute, now and on every change the page makes
function pageRule({ source, spec }) {
  // eslint-disable-next-line no-new-func
  const { makeRenamer, wbrRuns, renameRuns } = new Function(
    "module",
    `${source}; return { makeRenamer, wbrRuns, renameRuns };`,
  )({});
  const r = makeRenamer(spec);
  // an element's child nodes as rename.js's wbrRuns reads them (the gate in pageText reads them the same way)
  const pieces = (el) =>
    [...el.childNodes].map((n) =>
      n.nodeType === Node.TEXT_NODE ? { text: n.nodeValue } : n.nodeName === "WBR" ? { wbr: true } : { element: true },
    );
  window.__wbrWords = (el) => wbrRuns(pieces(el)).map((run) => run.text);
  const hasWbr = (el) => [...el.children].some((c) => c.tagName === "WBR");
  // every attribute but these: what draws the page (an icon's src keeps loading), never words
  const SKIP = new Set(["class", "style", "src", "srcset", "id", "d", "viewBox", "fill", "stroke", "transform"]);
  const fix = (node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      const t = r.text(node.nodeValue);
      if (t !== node.nodeValue) node.nodeValue = t;
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    // a word split by <wbr> (the Links rail breaks a repo name at its _) is one word on screen: renamed as one, only
    // its text pieces rewritten (the element's other children and the <wbr> stay)
    if (hasWbr(node)) {
      const nodes = [...node.childNodes];
      for (const [i, t] of renameRuns(pieces(node), r.text)) nodes[i].nodeValue = t;
    }
    for (const { name, value } of [...node.attributes]) {
      if (SKIP.has(name)) continue;
      const t = r.text(value);
      if (t !== value) node.setAttribute(name, t);
    }
    if ((node.tagName === "INPUT" || node.tagName === "TEXTAREA") && node.value) {
      const t = r.text(node.value);
      if (t !== node.value) node.value = t;
    }
    if (node.shadowRoot) node.shadowRoot.childNodes.forEach(fixAll);
  };
  const fixAll = (root) => {
    fix(root);
    const w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    while (w.nextNode()) fix(w.currentNode);
  };
  window.__renameAll = () => fixAll(document.documentElement);
  const start = () => {
    fixAll(document.documentElement);
    new MutationObserver((ms) => {
      for (const m of ms) {
        if (m.type === "characterData") fix(m.target);
        else if (m.type === "attributes") fix(m.target);
        else m.addedNodes.forEach(fixAll);
      }
    }).observe(document.documentElement, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
    });
  };
  if (document.documentElement) start();
  else document.addEventListener("DOMContentLoaded", start);
}

// what the gate reads: every word the page shows and every attribute that can carry a name or a link
function pageText() {
  // every text node of the document (what is drawn and what is clipped, folded or hidden until hover; the head's
  // title, the open dialogs, SVG <text> included), one node per line — never innerText, which glues neighbours
  // ("description." + "Terminals" reads as a host)
  const parts = [];
  const w = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_TEXT);
  while (w.nextNode()) {
    const tag = w.currentNode.parentElement?.tagName;
    if (tag !== "SCRIPT" && tag !== "STYLE") parts.push(w.currentNode.nodeValue); // code and styles are never shown
  }
  for (const el of document.querySelectorAll("*")) {
    // a word split by <wbr> reads as one word: each joined word too (one text node per piece would hide it); the
    // pieces are read by the init script's rename.js (pageRule), never by a second copy of the rule
    if ([...el.children].some((c) => c.tagName === "WBR")) {
      if (typeof window.__wbrWords !== "function") throw new Error("capture-live: the rename rule is not in the page");
      parts.push(...window.__wbrWords(el));
    }
    for (const a of el.attributes) {
      // what a reader can see or follow: tooltips, labels, links, alt text, form values (not src: a picture's address)
      if (/^(title|aria-.*|href|alt|placeholder|value|data-.*|content)$/.test(a.name)) parts.push(a.value);
    }
    if ((el.tagName === "INPUT" || el.tagName === "TEXTAREA") && el.value) parts.push(el.value);
  }
  return parts.join("\n");
}

const openWorkflow = async (page) => {
  await page.getByRole("button", { name: "Workflow", exact: true }).click();
  await page.waitForSelector("dialog.kb-be[open] .kb-be-graph .kb-be-line", { state: "attached" });
};

const SHOTS = [
  { name: "today", url: `${WEB}/`, ready: ".heatmap", viewport: DESKTOP },
  { name: "board", url: BOARD, ready: ".kb-board .kb-card", viewport: { width: 1440, height: 1400 } },
  { name: "card", url: `${BOARD}&card=${CARD}`, ready: "dialog.kb-dialog[open]", viewport: DESKTOP },
  { name: "today-mobile", url: `${WEB}/`, ready: ".heatmap", viewport: { width: 390, height: 844 } },
  {
    name: "workflow",
    url: BOARD,
    ready: ".kb-board",
    viewport: { width: 1440, height: 2500 }, // tall: the whole graph, top to bottom, at its reading size
    before: openWorkflow,
    crop: "dialog.kb-be[open]",
  },
];

const settled = (page) =>
  page.evaluate(async () => {
    await document.fonts.ready;
    const finite = document.getAnimations().filter((a) => a.effect?.getComputedTiming().iterations !== Infinity);
    await Promise.all(finite.map((a) => a.finished));
    window.__renameAll();
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  });

async function main() {
  const spec = await readSpec();
  const rule = makeRenamer(spec);
  const source = fs.readFileSync(path.join(__dirname, "rename.js"), "utf8");
  const [cookieName, ...rest] = COOKIE.split("=");
  const browser = await chromium.launch();
  const verdicts = {};
  const pngs = {};
  try {
    for (const shot of SHOTS) {
      const ctx = await browser.newContext({ viewport: shot.viewport, deviceScaleFactor: SCALE });
      await ctx.addCookies([{ name: cookieName, value: rest.join("="), domain: ORIGIN.hostname, path: "/" }]);
      await ctx.addInitScript((skin) => localStorage.setItem("busyyaks.skin", skin), SKIN);
      await ctx.addInitScript(pageRule, { source, spec });
      let closing = false; // after the screenshot: the page's polls still in flight are dropped with the context
      await ctx.route("**/*", (route) =>
        serve(route).catch((e) => {
          if (!closing) throw e;
        }),
      );
      const serve = async (route) => {
        const u = new URL(route.request().url());
        if (u.host !== ORIGIN.host) return route.abort(); // only the local dashboard: no person's picture, no tracker
        // pictures carry words no text gate reads: a card's attachments are drawn as a text-free sample picture
        // (samples.js, by the attachment's id), another project's icon is not served (the page shows its initials)
        if (u.pathname.startsWith("/api/attachments/")) {
          const id = u.pathname.split("/")[3];
          return route.fulfill({ status: 200, contentType: "image/svg+xml", body: samplePicture(id).svg });
        }
        if (u.pathname.startsWith("/api/icons/") && decodeURIComponent(u.pathname.slice(11)) !== OWN)
          return route.fulfill({ status: 404, contentType: "application/json", body: '{"error":"not shown"}' });
        if (!u.pathname.startsWith("/api/")) return route.continue();
        const res = await route.fetch();
        const type = res.headers()["content-type"] ?? "";
        if (!type.includes("json")) return route.fulfill({ response: res });
        return route.fulfill({ response: res, json: rule.json(await res.json()) });
      };
      const page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      await page.goto(shot.url, { waitUntil: "networkidle" });
      await page.waitForSelector(shot.ready).catch(async (e) => {
        // the page as it stands and its errors, for whoever runs this (RAW is the operator's private workdir)
        await page.screenshot({ path: `${RAW}/${shot.name}-not-ready.png` });
        throw new Error(
          `capture-live: ${shot.name}: ${e.message.split("\n")[0]}; page errors: ${errors.join(" | ") || "none"}`,
        );
      });
      // the live board's launch-failure alert (the engine's LaunchFailureAlert: a lead that ended, a start that failed)
      // is the operator's notice of the moment, not part of the page: dismissed as the operator would, with its OK —
      // once the page is ready and again once it has settled (it opens when /api/waiting answers); one still open at
      // the screenshot refuses the run
      const alert = page.locator("dialog.ak-alert[open]");
      const dismissAlert = async () => {
        if (!(await alert.isVisible())) return;
        await alert.locator(".ak-alert-actions button").click();
        await alert.waitFor({ state: "hidden" });
      };
      await dismissAlert();
      if (shot.before) await shot.before(page);
      await settled(page);
      await dismissAlert();
      await settled(page);
      if (await alert.isVisible()) throw new Error(`capture-live: ${shot.name}: the launch alert is still open`);
      let clip = { x: 0, y: 0, ...shot.viewport };
      if (shot.crop) {
        const r = await page.locator(shot.crop).boundingBox();
        if (!r) throw new Error(`capture-live: ${shot.name}: ${shot.crop} has no box`);
        clip = { x: Math.floor(r.x), y: Math.floor(r.y), width: Math.ceil(r.width), height: Math.ceil(r.height) };
      }
      const text = await page.evaluate(pageText);
      const bg = await page.evaluate(() => ({
        skin: document.documentElement.dataset.skin,
        body: getComputedStyle(document.body).backgroundColor,
        token: getComputedStyle(document.documentElement).getPropertyValue("--bg").trim(),
      }));
      const png = await page.screenshot({ clip });
      verdicts[shot.name] = { leaks: leaks(text, spec), background: bg };
      fs.writeFileSync(`${RAW}/${shot.name}.txt`, text);
      fs.writeFileSync(`${RAW}/${shot.name}.png`, png);
      pngs[shot.name] = png;
      closing = true;
      await ctx.close();
    }
    fs.writeFileSync(`${RAW}/gate.json`, JSON.stringify(verdicts, null, 2));
    const bad = Object.entries(verdicts).filter(([, v]) => v.leaks.length || v.background.skin !== "dark");
    if (bad.length) {
      for (const [name, v] of bad)
        console.error(
          `capture-live: ${name}: skin ${v.background.skin}; ${v.leaks.map((l) => l.join(" @ ")).join("; ")}`,
        );
      throw new Error("capture-live: the gate refused the images above; nothing written to OUT");
    }
    // only now: the images, WebP
    const blank = await (await browser.newContext()).newPage();
    for (const [name, png] of Object.entries(pngs)) {
      const url = await blank.evaluate(
        ({ b64, q }) =>
          new Promise((resolve, reject) => {
            const img = new Image();
            img.onerror = () => reject(new Error("capture-live: the screenshot did not decode"));
            img.onload = () => {
              const c = document.createElement("canvas");
              c.width = img.width;
              c.height = img.height;
              c.getContext("2d").drawImage(img, 0, 0);
              resolve(c.toDataURL("image/webp", q));
            };
            img.src = `data:image/png;base64,${b64}`;
          }),
        { b64: png.toString("base64"), q: QUALITY },
      );
      const file = `${OUT}/${name}.webp`;
      fs.writeFileSync(file, Buffer.from(url.split(",")[1], "base64"));
      console.log(`${name}.webp ${fs.statSync(file).size} bytes · background ${verdicts[name].background.body}`);
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
