// The rename rule's input (scripts/readme-images/rename.js specFrom), read from the operator's live dashboard: its
// projects and groups (GET /api/projects), the repos Today names (GET /api/today), busyyaks' own slug and public repos,
// the private terms and the operator's name. Shared by the live captures (capture-live.js) and the screenshot
// environment's dump (dump.js). Nothing it reads is written anywhere: the spec lives in memory.
"use strict";

const fs = require("fs");
const { specFrom, mergedRepos } = require("./rename.js");

const lines = (file) =>
  fs
    .readFileSync(file, "utf8")
    .split("\n")
    .map((t) => t.trim())
    .filter((t) => t && !t.startsWith("#"));

// web: http://127.0.0.1:<port>; cookie: rack.session=…; own: busyyaks' slug; keep: the other projects shown as they
// are ("slug slug", may be empty); ownRepos: "owner/repo owner/repo";
// termsFile / namesFile: one entry per line (# comments)
async function liveSpec({ web, cookie, own, keep, ownRepos, termsFile, namesFile, who }) {
  const api = async (p) => {
    const res = await fetch(`${web}${p}`, { headers: { Cookie: cookie } });
    if (!res.ok) throw new Error(`${who}: GET ${p}: ${res.status}`);
    return res.json();
  };
  const tree = (await api("/api/projects")).tree;
  const slugs = [];
  const groups = [];
  const walk = (n) => {
    if (n.project) slugs.push(n.project.slug);
    else if (n.path) groups.push(n.path);
    (n.children ?? []).forEach(walk);
  };
  tree.forEach(walk);
  const today = await api("/api/today");
  const spec = specFrom({
    slugs,
    groups,
    repos: mergedRepos(today),
    own,
    keep: keep.split(/\s+/).filter(Boolean),
    ownRepos: ownRepos.split(/\s+/).filter(Boolean),
    terms: lines(termsFile),
    people: lines(namesFile),
  });
  return { spec, today, api };
}

module.exports = { liveSpec, lines };
