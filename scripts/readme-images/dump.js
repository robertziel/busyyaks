// The README screenshot environment's dump (scripts/readme-images/dump): busyyaks' own live board (dump-board.rb's
// raw JSON), its commit subjects and its merged PRs, RENAMED by the rule (rename.js) and GATED (`leaks`) before
// anything is kept — the demo stack loads what this writes (load-dump.rb), so a word that passes here can reach a
// README image. One leak in the TEXT refuses the whole dump, naming where (table, row, field), never the word. The
// pictures: tesseract read each candidate (dump runs it); a card keeps its newest candidate whose words pass the same
// gate (the README card: its newest PICTURES), a failing one is skipped for the next and named in report.json (card,
// picture, kinds) ; a card with none that passes shows no picture.
//
//   node dump.js extract <raw.json> <dir>                       the raw pictures to <dir>/<id>.<ext>, for tesseract
//   node dump.js gate <raw.json> <ocr dir> <commits.tsv> <out>  rename + gate → <out>/{board.json,commits.tsv,
//                                                                 merged.json,attachments/<id>}
//
// Env (gate): DROP_FILE (optional: picture ids the operator ruled out, one per line, # comments), PICTURES (the README card's picture count), WEB, COOKIE_FILE, OWN (busyyaks' working slug on the dashboard), KEEP (the other projects shown as they are), OWN_REPOS (busyyaks' public repos and
// its engine's), TERMS, NAMES — as capture-live.js. The demo's names for those repos (repoMap): each public repo →
// DEMO_OWNER/<its name>, its enrolled local repo → DEMO_OWNER/<its name>_dev (the demo stack enrols its busyyaks repo
// with exactly these remotes).
"use strict";

const fs = require("fs");
const path = require("path");
const { makeRenamer, leaks, nameRegExp } = require("./rename.js");
const { liveSpec } = require("./live-spec.js");

const DEMO_OWNER = "dev-example";
const DEMO_SLUG = "busyyaks";
const PRIVATE = "private"; // what a private term reads as in the dump's text
const EXT = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif" };

// Card fields that name a live session or a live check: never carried into the demo (its own sessions adopt the cards)
const DROPPED = [
  "owner_session",
  "owner_socket",
  "owner_missing_since",
  "dialog_id",
  "gate_head",
  "gate_state",
  "progress_at",
  "progress_marks",
  "progress_pinged_at",
  "progress_commented_at",
  "progress_stale_at",
  "progress_error",
];

const ext = (a) => {
  const e = EXT[a.content_type];
  if (!e) throw new Error(`dump: attachment ${a.id} is ${a.content_type}, not a picture type the dump keeps`);
  return e;
};

function extract(rawFile, dir) {
  const raw = JSON.parse(fs.readFileSync(rawFile, "utf8"));
  fs.mkdirSync(dir, { recursive: true });
  for (const a of raw.attachments)
    fs.writeFileSync(path.join(dir, `${a.id}.${ext(a)}`), Buffer.from(a.bytes, "base64"));
  console.log(`dump: ${raw.attachments.length} pictures for tesseract`);
}

// owner/name of busyyaks' repos → the demo's names, wherever a string spells them (a URL, a bare owner/repo): each
// enrolment whose public repo is one of busyyaks' (OWN_REPOS: busyyaks', its engine's) → its local repo
// DEMO_OWNER/<public name>_dev, its public repo DEMO_OWNER/<public name>
const ghName = (url) => (url ?? "").replace(/^(https:\/\/github\.com\/|git@github\.com:)/, "").replace(/\.git$/, "");
function repoMap(enrolments, ownRepos, ownSlug = null) {
  const pairs = []; // [real, demo, bare?]
  const seams = [];
  for (const pub of ownRepos) {
    const name = pub.split("/").pop();
    pairs.push([pub, `${DEMO_OWNER}/${name}`, false]);
    const e = enrolments.find((x) => ghName(x.public_repo).toLowerCase() === pub.toLowerCase());
    if (!e || !ghName(e.local_repo)) throw new Error(`dump: no enrolled project has ${pub} as its public repo`);
    const local = ghName(e.local_repo);
    pairs.push([local, `${DEMO_OWNER}/${name}_dev`, false]);
    // the private repo's name alone (a Links rail row, a path) is private too: → <public name>_dev
    const bare = local.split("/").pop();
    // the seam a picture's words still show when tesseract interleaves columns: the public name's last word + what the
    // private name adds (tool + _private → "toolprivate"); the whole private name when it does not extend the public one
    const flatName = (x) => x.replace(/[\s_/-]+/g, "").toLowerCase();
    seams.push(
      bare.toLowerCase().startsWith(name.toLowerCase())
        ? flatName(name.split(/[_-]/).pop() + bare.slice(name.length))
        : flatName(bare),
    );
    // (not busyyaks' own working slug: the rule renames that one to busyyaks)
    const skip = [name.toLowerCase(), (ownSlug ?? "").toLowerCase()];
    if (!skip.includes(bare.toLowerCase())) pairs.push([bare, `${name}_dev`, true]);
  }
  pairs.sort((a, b) => b[0].length - a[0].length);
  const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // owner/name anywhere but inside a longer name; a bare name never right after a / (an owner/name's own part)
  const res = pairs.map(([real, demo, bare]) => [
    new RegExp(`(^|[^A-Za-z0-9._${bare ? "/" : ""}-])${esc(real)}(?![A-Za-z0-9_-])`, "gi"),
    demo,
  ]);
  const map = (s) => (typeof s === "string" ? res.reduce((o, [re, d]) => o.replace(re, (m, pre) => pre + d), s) : s);
  // demo: every demo name (the structured fields' allowed set); owned: the owner/name ones (the rule's own repos)
  return {
    seams,
    map,
    demo: pairs.map(([, d]) => d),
    owned: pairs.filter(([, , b]) => !b).map(([, d]) => d),
    real: pairs.map(([r]) => r),
  };
}

// The pictures a card keeps: its candidates newest first (dump-board.rb's order), the first that pass (no kind of leak
// in what tesseract read: kindsOf(attachment) → []) — 1 per card, `want` for the README card. Every one that fails is
// skipped and named: {card, picture, kinds}.
function choosePictures(candidates, readmeCard, want, kindsOf) {
  const chosen = [];
  const skipped = [];
  const byCard = new Map();
  for (const a of candidates) byCard.set(a.card_id, [...(byCard.get(a.card_id) ?? []), a]);
  for (const [cid, list] of byCard) {
    const n = cid === readmeCard ? want : 1;
    const keep = [];
    for (const a of list) {
      if (keep.length === n) break;
      const kinds = kindsOf(a);
      if (kinds.length) skipped.push({ card: cid, picture: a.id, kinds });
      else keep.push(a);
    }
    chosen.push(...keep);
  }
  return { chosen, skipped };
}

// What a picture's words leak (its text as tesseract read it): the text as read, the text re-joined where the page
// wrapped a name at _ or - (the Links rail breaks a repo name at its _: tesseract reads one piece per line), and — for
// the private terms, which are substrings — the text and the terms with every space, _, / and - removed (tesseract
// reads an _ as a space). Kinds, deduplicated.
function pictureKinds(text, gateSpec) {
  const joined = text.replace(/([_-])[ \t]*\r?\n[ \t]*/g, "$1");
  const kinds = [...leaks(text, gateSpec), ...leaks(joined, gateSpec)].map(([k]) => k);
  // tesseract reads an _ as a space and interleaves two columns: compare with every space, _, / and - removed
  const flat = (x) => x.replace(/[\s_/-]+/g, "").toLowerCase();
  const bare = flat(text);
  if (gateSpec.terms.some((t) => flat(t) && bare.includes(flat(t)))) kinds.push("private term");
  if ((gateSpec.seams ?? []).some((t) => bare.includes(t))) kinds.push("private repo name");
  return [...new Set(kinds)];
}

// The gate: every word that can reach the demo (the board's tables, the merged PRs, the commit subjects), each leak
// named where it is (table, row, field — never the word); a repo field must be one of the demo's names
function findLeaks({ board, merged, commits }, gateSpec, demoNames) {
  const found = [];
  const check = (where, s) => {
    if (typeof s !== "string" || s === "") return;
    for (const [kind, detail] of leaks(s, gateSpec)) found.push(`${kind} (${detail}) in ${where}`);
  };
  const walk = (where, v) =>
    Array.isArray(v)
      ? v.forEach((x, i) => walk(`${where}[${i}]`, x))
      : v && typeof v === "object"
        ? Object.entries(v).forEach(([k, x]) => walk(`${where}.${k}`, x))
        : check(where, v);
  const structured = new Set(demoNames);
  for (const [table, rows] of Object.entries(board)) {
    if (!Array.isArray(rows)) continue;
    rows.forEach((row) => {
      for (const [k, v] of Object.entries(row)) {
        const where = `${table} ${row.id ?? "?"} ${k}`;
        if (k === "file") continue; // the dump's own file name (<id>.<ext>), never shown
        if (k === "repo") {
          if (!structured.has(v)) found.push(`a repo outside the demo's names in ${where}`);
          continue;
        }
        if (k === "metadata" && v) {
          const m = JSON.parse(v);
          for (const p of [...(m.prs ?? []), ...(m.prs_removed ?? [])])
            if (!structured.has(p.repo)) found.push(`a PR repo outside the demo's names in ${where}`);
          walk(where, {
            ...m,
            prs: (m.prs ?? []).map(({ repo, ...p }) => p),
            prs_removed: (m.prs_removed ?? []).map(({ repo, ...p }) => p),
          });
          continue;
        }
        walk(where, v);
      }
    });
  }
  merged.forEach((p, i) => {
    if (!structured.has(p.repo)) found.push(`a repo outside the demo's names in merged ${i}`);
    check(`merged ${i} title`, p.title);
    check(`merged ${i} url`, p.url);
  });
  commits.forEach(([, s], i) => check(`commit ${i + 1}`, s));
  return [...new Set(found)];
}

// The dump's whole transformation, pure: raw = dump-board.rb's JSON; todayMerged = /api/today's merged_prs;
// commitsText = `<epoch>\t<subject>` lines; spec = the live rule's spec (live-spec.js); ownRepos = busyyaks' public
// repos; pictures = the README card's picture count; ocrText(attachment) = what tesseract read in it; drop = picture
// ids the operator ruled out.
// → {board, merged, commits, chosen, skipped, found}: found empty = the gate passed.
function buildDump({ raw, todayMerged, commitsText, spec, ownRepos, pictures, ocrText, drop = [] }) {
  const repos = repoMap(raw.enrolments, ownRepos, Object.keys(spec.own)[0]);
  // the demo's repo names are busyyaks' own: kept behind github.com/, shown by their name alone as text
  const demoSpec = { ...spec, ownRepos: repos.owned };
  const r = makeRenamer(demoSpec);
  // the real owners of busyyaks' repos (a GitHub login: the operator's, an org's): renamed to DEMO_OWNER wherever a
  // word spells one that the repo map did not (another of its repos, a gist), and refused by the gate like a term
  const owners = [...new Set(repos.real.map((x) => x.split("/")[0].toLowerCase()))].filter((o) => o !== DEMO_OWNER);
  const ownerRes = owners.map((o) => nameRegExp(o, "gi"));
  // the gate's names: the private terms + every real repo name and owner, as substrings (a picture's words are never
  // renamed: this is their only check)
  const gateSpec = { ...demoSpec, terms: [...spec.terms, ...repos.real, ...owners], seams: repos.seams };
  // busyyaks' own text that still holds a private term once renamed (a path, a launcher's name, a trailer): each
  // occurrence → PRIVATE, any case, longest term first
  const terms = [...spec.terms]
    .sort((a, b) => b.length - a.length)
    .map((t) => new RegExp(t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"));
  const scrub = (s) => terms.reduce((o, re) => o.replace(re, PRIVATE), s);
  const unowned = (s) => ownerRes.reduce((o, re) => o.replace(re, (m, pre) => pre + DEMO_OWNER), s);
  const text = (s) => (typeof s === "string" ? unowned(scrub(r.text(repos.map(s)))) : s);
  const deep = (v) =>
    Array.isArray(v)
      ? v.map(deep)
      : v && typeof v === "object"
        ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, deep(x)]))
        : text(v);
  const json = (s, f) => (s === null || s === undefined ? s : JSON.stringify(f(JSON.parse(s))));
  // a PR entry's repo is a structured name (the board checks it against the enrolment): mapped, never shortened
  const prs = (list) => (list ?? []).map((p) => ({ ...deep(p), repo: repos.map(p.repo), url: text(p.url) }));
  const meta = (m) => ({
    ...deep(m),
    ...(m.prs ? { prs: prs(m.prs) } : {}),
    ...(m.prs_removed ? { prs_removed: prs(m.prs_removed) } : {}),
  });

  const cards = raw.cards.map((c) => {
    const o = { ...c, project_slug: DEMO_SLUG };
    for (const k of DROPPED) o[k] = null;
    for (const k of [
      "title",
      "notes",
      "assignee",
      "priority",
      "created_by",
      "approved_by",
      "qa_notes",
      "pr_url",
      "ci_url",
      "handoff_by",
      "question",
      "asked_by",
      "blocked_author",
      "blocked_reason",
      "blocked_url",
    ])
      o[k] = text(c[k]);
    o.labels = json(c.labels, deep);
    o.question_options = json(c.question_options, deep);
    o.metadata = json(c.metadata, meta);
    return o;
  });
  // a picture the operator ruled out (the drop list) is skipped like one that fails the gate
  const dropped = new Set(drop.map(Number));
  const { chosen, skipped } = choosePictures(raw.attachments, raw.card, pictures, (a) =>
    dropped.has(a.id) ? ["on the drop list"] : pictureKinds(ocrText(a), gateSpec),
  );
  const board = {
    slug: DEMO_SLUG,
    card: raw.card,
    exported_at: raw.exported_at,
    columns: raw.columns.map((c) => ({ ...c, project_slug: DEMO_SLUG, label: text(c.label) })),
    transitions: raw.transitions.map((t) => ({ ...t, project_slug: DEMO_SLUG, name: text(t.name) })),
    labels: raw.labels.map((l) => ({ ...l, project_slug: DEMO_SLUG, name: text(l.name) })),
    cards,
    activity: raw.activity.map((a) => ({ ...a, body: text(a.body), author: text(a.author) })),
    checklists: raw.checklists.map((c) => ({ ...c, title: text(c.title) })),
    items: raw.items.map((i) => ({ ...i, body: text(i.body), done_by: text(i.done_by) })),
    attachments: chosen.map(({ bytes, ...a }) => ({
      ...a,
      filename: text(a.filename),
      uploaded_by: text(a.uploaded_by),
      file: `${a.id}.${ext(a)}`,
    })),
    pr_states: raw.pr_states.map((p) => ({
      ...p,
      repo: repos.map(p.repo),
      url: text(p.url),
      error: text(p.error),
      reason: text(p.reason),
    })),
  };
  // busyyaks' merged PRs from Today (its working repo and its public ones), in the demo's repo names
  const own = new Set(repos.real.map((x) => x.toLowerCase()));
  const merged = todayMerged
    .filter((p) => own.has(p.repo.toLowerCase()))
    .map((p) => ({
      repo: repos.map(p.repo),
      number: p.number,
      title: text(p.title),
      url: text(p.url),
      merged_at: p.merged_at,
    }));
  const commits = commitsText
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      const tab = l.indexOf("\t");
      const at = l.slice(0, tab);
      if (tab < 0 || !/^\d+$/.test(at)) throw new Error(`dump: a commits line without its time: ${l.length} bytes`);
      return [at, text(l.slice(tab + 1).replace(/\t/g, " "))];
    });

  const found = findLeaks({ board, merged, commits }, gateSpec, repos.demo);
  return { board, merged, commits, chosen, skipped, found };
}

// the drop list's ids: one per line, # comments, blank lines skipped; anything else refused
function dropList(text) {
  return text
    .split("\n")
    .map((l) => l.replace(/#.*/, "").trim())
    .filter(Boolean)
    .map((l) => {
      if (!/^\d+$/.test(l)) throw new Error(`dump: the drop list holds ${JSON.stringify(l)}, not a picture id`);
      return l;
    });
}

async function gate(rawFile, ocrDir, commitsFile, out) {
  const { WEB, COOKIE_FILE, OWN, KEEP, OWN_REPOS, TERMS, NAMES } = process.env;
  const PICTURES = Number(process.env.PICTURES);
  if (!WEB || !COOKIE_FILE || !OWN || KEEP === undefined || !OWN_REPOS || !TERMS || !NAMES || !(PICTURES > 0))
    throw new Error("dump: PICTURES, WEB, COOKIE_FILE, OWN, KEEP, OWN_REPOS, TERMS and NAMES are required");
  const cookie = fs.readFileSync(COOKIE_FILE, "utf8").trim();
  const ownRepos = OWN_REPOS.split(/\s+/).filter(Boolean);
  const { spec, today } = await liveSpec({
    web: WEB,
    cookie,
    own: OWN,
    keep: KEEP,
    ownRepos: OWN_REPOS,
    termsFile: TERMS,
    namesFile: NAMES,
    who: "dump",
  });
  const raw = JSON.parse(fs.readFileSync(rawFile, "utf8"));
  const { board, merged, commits, chosen, skipped, found } = buildDump({
    raw,
    todayMerged: today.merged_prs,
    commitsText: fs.readFileSync(commitsFile, "utf8"),
    spec,
    ownRepos,
    pictures: PICTURES,
    drop: process.env.DROP_FILE ? dropList(fs.readFileSync(process.env.DROP_FILE, "utf8")) : [],
    ocrText: (a) => {
      const t = path.join(ocrDir, `${a.id}.txt`);
      if (!fs.existsSync(t)) throw new Error(`dump: picture ${a.id} was not read by tesseract`);
      return fs.readFileSync(t, "utf8");
    },
  });
  if (found.length) {
    console.error(`dump: the gate refused the dump (${found.length}):\n${found.join("\n")}`);
    process.exit(1);
  }

  fs.mkdirSync(path.join(out, "attachments"), { recursive: true });
  for (const a of chosen)
    fs.writeFileSync(path.join(out, "attachments", `${a.id}.${ext(a)}`), Buffer.from(a.bytes, "base64"));
  fs.writeFileSync(
    path.join(out, "report.json"),
    JSON.stringify({ kept: chosen.map((a) => ({ card: a.card_id, picture: a.id })), skipped }, null, 1),
  );
  fs.writeFileSync(path.join(out, "board.json"), JSON.stringify(board));
  fs.writeFileSync(path.join(out, "card"), `${raw.card}\n`); // the README card's id (build opens it)
  fs.writeFileSync(path.join(out, "merged.json"), JSON.stringify(merged));
  fs.writeFileSync(path.join(out, "commits.tsv"), commits.map(([at, s]) => `${at}\t${s}`).join("\n") + "\n");
  console.log(
    `dump: gate passed · ${board.cards.length} cards · ${board.activity.length} activity · ${board.attachments.length} pictures (${skipped.length} skipped: report.json) · ` +
      `${commits.length} commits · ${merged.length} merged PRs → ${out}`,
  );
  // the gate reads a picture's WORDS only: a face, a logo or an icon passes it — look at the kept ones once
  console.log(
    `dump: kept pictures (look at them before the first build), under attachments/: ${chosen.map((a) => `${a.id}.${ext(a)}`).join(" ")}`,
  );
}

module.exports = { repoMap, choosePictures, pictureKinds, buildDump, findLeaks, dropList, DEMO_OWNER };

if (require.main === module) {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === "extract" && args.length === 2) extract(...args);
  else if (cmd === "gate" && args.length === 4)
    gate(...args).catch((e) => {
      console.error(e.message);
      process.exit(1);
    });
  else {
    console.error("usage: dump.js extract <raw.json> <dir> | gate <raw.json> <ocr dir> <commits.tsv> <out>");
    process.exit(2);
  }
}
