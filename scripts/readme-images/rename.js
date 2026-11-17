// The README's live captures (scripts/readme-images/live): the RULE that renames everything on the operator's own
// dashboard that is not busyyaks before a screenshot is taken, and the GATE that refuses an image on anything left.
// No real name is in this file or anywhere in the repo — the names are read from the live dashboard at capture time
// (GET /api/projects, /api/today) and live only in memory:
//
//   busyyaks' own working slug (the live checkout's dir)  → busyyaks (every spelling)
//   the projects named in spec input `keep` (KEEP)        → kept as they are (busyyaks' own other projects); every
//                                                            name is still checked by the gate's terms
//   busyyaks' public repos (spec.ownRepos)                → kept; every other owner/repo is another project
//   every other project and group, in /api/projects order → acme-N / group-N: its slug, its slug as a tmux session
//                                                            name, its repo name, each with _ - / spellings, as a
//                                                            whole word anywhere, any case (an ordinary word that is
//                                                            also a project's name is renamed too)
//   a card, commit, report or question of another project → "Task N" / "Commit N" / … (its text never shown)
//   another project's tmux session / agent                → agent_N (claude-agent_N, …), also in its links
//   busyyaks' own text that holds a private term          → the same placeholders (the term list: read at capture
//                                                            time from the private-term files, never written here)
//   an email                                              → "operator" (no @ left)
//   a commit author's name, the operator's name (any word) → "Dev Example"
//   a host other than 127.0.0.1 / localhost / github.com  → ci.example.com (an IPv4 address → 192.0.2.1)
//   the host of an ssh command (an attach template)       → box
//   github.com/<owner>/<repo> that is not busyyaks'       → github.com/acme/acme-repo
//
// Used twice with the same spec: on every /api JSON answer before the page reads it (json: another project's free
// text and names — busyyaks' own slug stays, the app routes by it), and on the page's text nodes and attributes as it
// renders (text: every name, emails, hosts) — scripts/readme-images/capture-live.js. Then `leaks` refuses the images
// on anything that survived. Tested by frontend/src/readmeImages.test.ts.
"use strict";

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// A name as a whole word: never inside a longer word (letters, digits); any case
function nameRegExp(name, flags = "i") {
  return new RegExp(`(^|[^A-Za-z0-9])${esc(name)}(?![A-Za-z0-9])`, flags);
}

// Every spelling a project's name takes on the page: its slug, the slug as a tmux session name (/ and . → _), its
// repo name — each with _ - and / swapped (a dir, a branch, a session or a GitHub repo spells it any of these ways).
function nameVariants(slug) {
  const forms = [slug, slug.replace(/[/.]/g, "_"), slug.split("/").pop()];
  const spell = (f) => [
    f,
    f.replace(/_/g, "-"),
    f.replace(/-/g, "_"),
    f.replace(/[/_]/g, "-"),
    f.replace(/[-_]/g, "/"),
  ];
  return [...new Set(forms.flatMap(spell))].filter((n) => n && !/^\/|\/$/.test(n));
}

// A host the page could show: a dotted name whose last label (letters only, as a top-level domain is) is no file
// extension, or an IPv4 address; with or
// without a scheme or a path. The hosts a README image may keep: this machine, GitHub, the rule's own stand-ins.
const FILE_EXT =
  /^(rb|js|mjs|cjs|ts|tsx|jsx|md|yml|yaml|json|css|scss|html|erb|sh|py|txt|log|png|jpe?g|webp|svg|gif|lock|sql|toml|env|example|conf|ini|xml|csv|gz|tar|zip|pem|key|crt|d|sock|pid|service|timer|desktop|plist|icns|rake|gemspec|ru|mdx)$/i;
const HOST = /(^|[^A-Za-z0-9.@_-])((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}|\d{1,3}(?:\.\d{1,3}){3})(?![A-Za-z0-9_-])/g;
const KEPT_HOSTS = new Set(["127.0.0.1", "localhost", "github.com", "ci.example.com", "192.0.2.1"]);
const isHost = (h) => /^\d/.test(h) || !FILE_EXT.test(h.split(".").pop());
const hostsIn = (s) => [...s.matchAll(HOST)].map((m) => ({ host: m[2], index: m.index })).filter((h) => isHost(h.host));
const GITHUB_REPO = /\bgithub\.com\/([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+)/g;
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g;

// The GitHub repos /api/today names (your merged PRs): every one of them, or an error naming what is missing
function mergedRepos(today) {
  if (!today || !Array.isArray(today.merged_prs))
    throw new Error("readme-images: /api/today has no merged_prs list: the repos it names cannot be renamed");
  return today.merged_prs.map((p, i) => {
    if (typeof p?.repo !== "string" || p.repo === "")
      throw new Error(`readme-images: /api/today merged_prs[${i}] has no repo`);
    return p.repo;
  });
}

// The rule's input from what the dashboard answers: busyyaks' own slug, everything else
function specFrom({ slugs, groups, repos, own, keep, ownRepos, terms, people }) {
  if (!slugs.includes(own)) throw new Error(`readme-images: ${own} is not a project on the dashboard`);
  if (!Array.isArray(keep)) throw new Error("readme-images: keep (the projects shown as they are) is required");
  for (const k of keep)
    if (k === own || !slugs.includes(k))
      throw new Error(`readme-images: keep: ${k} is not another project on the dashboard`);
  if (!ownRepos || ownRepos.length === 0) throw new Error("readme-images: no public repo of busyyaks (ownRepos)");
  if (!terms || terms.length === 0) throw new Error("readme-images: the term list holds no term");
  if (!people || people.length === 0) throw new Error("readme-images: no operator name to refuse");
  const kept = (s) => keep.includes(s);
  // busyyaks' own working repo on GitHub (<its public owner>/<own>) is busyyaks too: renamed to busyyaks, never to
  // acme-N; the same name under any other owner is another project
  const owner = ownRepos[0].split("/")[0];
  const ownRepo = (r) => r === `${owner}/${own}`;
  const others = [
    ...new Set([
      ...slugs.filter((s) => s !== own && !kept(s)),
      ...repos.filter((r) => !ownRepos.includes(r) && !ownRepo(r)),
    ]),
  ];
  return {
    own: { [own]: "busyyaks" },
    others,
    // a group that holds busyyaks' own slug or a kept project is busyyaks' too; every other group is renamed
    groups: groups.filter((g) => ![own, ...keep].some((s) => s.startsWith(`${g}/`))),
    ownRepos,
    terms,
    people,
  };
}

function makeRenamer(spec) {
  // spec: { own: {slug: generic}, others: [slug | owner/repo, …], groups: [path, …], ownRepos: [owner/repo], terms }
  const terms = spec.terms.map((t) => t.toLowerCase());
  const hasTerm = (s) => {
    const l = s.toLowerCase();
    return terms.some((t) => l.includes(t));
  };
  const pairs = [];
  const add = (real, generic) => real && real.toLowerCase() !== generic.toLowerCase() && pairs.push([real, generic]);
  for (const [real, generic] of Object.entries(spec.own)) nameVariants(real).forEach((n) => add(n, generic));
  spec.others.forEach((slug, i) => {
    const plain = new Set([slug, slug.split("/").pop()]); // its slug and repo name: acme-N; a session spelling: acme_N
    for (const name of nameVariants(slug))
      add(name, !plain.has(name) && name.includes("_") && !name.includes("-") ? `acme_${i + 1}` : `acme-${i + 1}`);
  });
  spec.groups.forEach((group, i) => nameVariants(group).forEach((name) => add(name, `group-${i + 1}`)));
  pairs.sort((a, b) => b[0].length - a[0].length); // longest first: a slug before its repo name
  const names = pairs.map(([real, generic]) => [nameRegExp(real, "gi"), generic]);
  const ownGenerics = new Set(Object.values(spec.own));
  const otherPairs = pairs.filter(([, g]) => !ownGenerics.has(g));
  // in the data: another project's names only, as a whole value or a path segment (busyyaks' own slug stays, the
  // app routes by it; a column key or a state that happens to be a project's name stays too — the page renames it)
  const exact = new Map(otherPairs);
  const slashed = otherPairs.filter(([real]) => real.includes("/"));
  const otherNames = (v) => {
    if (exact.has(v)) return exact.get(v);
    let out = v;
    for (const [real, g] of slashed) out = out.split(real).join(g);
    return out
      .split(/([/?&=#])/)
      .map((seg) => exact.get(seg) ?? seg)
      .join("");
  };
  const URL_HOST = /\b(https?:\/\/)([^/\s"'<>:]+)/g;
  const ownOwner = spec.ownRepos[0].split("/")[0];
  const isOwnWorkingRepo = (v) => v.split("/")[0] === ownOwner && Object.hasOwn(spec.own, v.split("/").pop());
  // the operator's name and its words, as whole words (busyyaks' public repo owner is a longer word: kept)
  const people = [...spec.people].sort((a, b) => b.length - a.length).map((n) => nameRegExp(n, "giu"));
  const SSH_HOST = /\bssh((?:\s+-\S+)*)\s+([A-Za-z0-9._@-]+)/g;

  const text = (s) => {
    if (typeof s !== "string" || s === "") return s;
    let out = s.replace(EMAIL, "operator").replace(SSH_HOST, (m, flags) => `ssh${flags} box`);
    out = out.replace(GITHUB_REPO, (m, owner, repo) => {
      if (spec.ownRepos.includes(`${owner}/${repo}`)) return m;
      // busyyaks' working repo (its public owner's only): shown as the public one
      if (owner === ownOwner && Object.hasOwn(spec.own, repo)) return `github.com/${spec.ownRepos[0]}`;
      return "github.com/acme/acme-repo";
    });
    out = out.replace(URL_HOST, (m, scheme, host) => (KEPT_HOSTS.has(host) ? m : `${scheme}ci.example.com`));
    out = out.replace(HOST, (m, pre, host) =>
      KEPT_HOSTS.has(host) || !isHost(host) ? m : `${pre}${/^\d/.test(host) ? "192.0.2.1" : "ci.example.com"}`,
    );
    for (const [re, generic] of names) out = out.replace(re, (m, pre) => `${pre}${generic}`);
    for (const re of people) out = out.replace(re, (m, pre) => `${pre}Dev Example`);
    return out;
  };

  // a JSON object that belongs to another project: its free text is replaced, never shown
  const PROJECT_KEYS = ["slug", "project", "project_slug", "repo"];
  const isRepo = (v) => /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(v);
  const otherValue = (v) =>
    spec.others.includes(v) || (isRepo(v) && !spec.ownRepos.includes(v) && !isOwnWorkingRepo(v));
  const isOther = (o) => PROJECT_KEYS.some((k) => typeof o[k] === "string" && otherValue(o[k]));
  const FREE = {
    title: "Task",
    subject: "Commit",
    question: "A question",
    question_first_line: "A question",
    handoff_first_line: "Handed over",
    blocked_first_line: "Waiting on CI",
    description: "A description.",
    description_html: "<p>A description.</p>",
    excerpt: "",
    html: "",
    body: "A comment.",
    body_html: "<p>A comment.</p>",
    summary: "",
    branch: "main",
    cwd: "",
    path: "",
    title_html: "",
  };
  // another project's tmux sessions and agents: agent_N (the same N for one session in every answer)
  const SESSION_KEYS = new Set(["name", "session", "owner_session", "key", "agent", "launched_by"]);
  // a session object: it carries a tmux socket or the session fields the agents sidebar and the launch bar read
  const isSession = (o) => "socket" in o || "agent_type" in o || "launcher" in o || "ssh_attach" in o;
  const sessions = new Map();
  const sessionName = (real) => {
    const key = real.replace(/^(claude|worker|team|qa|reviewer)-/, "").replace(/^default\//, "");
    if (!sessions.has(key)) sessions.set(key, `agent_${sessions.size + 1}`);
    return real === key ? sessions.get(key) : real.replace(key, sessions.get(key));
  };
  const counters = {};
  const seen = new Map();
  const placeholder = (key, value) => {
    const base = FREE[key];
    if (!/^(Task|Commit)$/.test(base)) return base;
    const k = `${key}\u0000${value}`;
    if (!seen.has(k)) seen.set(k, `${base} ${(counters[base] = (counters[base] ?? 0) + 1)}`);
    return seen.get(k);
  };

  const json = (v, other = false, key = "") => {
    if (Array.isArray(v)) return v.map((x) => json(x, other, key));
    if (v && typeof v === "object") {
      const mine = other || isOther(v);
      // the daily report summarises every project: its text is not shown
      const report = key === "latest" || (typeof v.html === "string" && typeof v.excerpt === "string");
      const out = {};
      const person = typeof v.email === "string"; // a commit: author + email
      // another project's session: its name wherever its fields carry it (attach commands, terminal links)
      const sess = mine && isSession(v) && typeof (v.name ?? v.session) === "string" ? (v.name ?? v.session) : null;
      const bare = sess && sess.replace(/^default\//, "");
      for (const [k, x] of Object.entries(v)) {
        if (person && k === "author" && typeof x === "string") out[k] = "Dev Example";
        else if (mine && typeof x === "string" && SESSION_KEYS.has(k) && isSession(v)) out[k] = sessionName(x);
        else if (
          typeof x === "string" &&
          Object.prototype.hasOwnProperty.call(FREE, k) &&
          (mine || report || hasTerm(x))
        )
          out[k] = placeholder(k, x);
        else if (bare && typeof x === "string" && x.includes(bare))
          out[k] = otherNames(x.split(bare).join(sessionName(bare)));
        else out[k] = json(x, mine, k);
      }
      return out;
    }
    return typeof v === "string" ? otherNames(v) : v;
  };

  return { text, json };
}

// What survived the rule in a page's text: [kind, where] for each — the found text itself is never returned
function leaks(text, spec) {
  const found = [];
  const lower = text.toLowerCase();
  spec.terms.forEach((t, i) => {
    if (lower.includes(t.toLowerCase())) found.push(["private term", `line ${i + 1} of the term list`]);
  });
  spec.people.forEach((n, i) => nameRegExp(n, "iu").test(text) && found.push(["operator's name", `word ${i + 1}`]));
  const email = text.match(EMAIL);
  if (email) found.push(["email", `offset ${email.index}`]);
  for (const m of text.matchAll(/\bhttps?:\/\/([^/\s"'<>:]+)/g))
    if (!KEPT_HOSTS.has(m[1])) found.push(["host", `offset ${m.index}`]);
  for (const h of hostsIn(text)) if (!KEPT_HOSTS.has(h.host)) found.push(["host", `offset ${h.index}`]);
  for (const m of text.matchAll(GITHUB_REPO)) {
    const repo = `${m[1]}/${m[2]}`;
    if (!spec.ownRepos.includes(repo) && repo !== "acme/acme-repo") found.push(["GitHub repo", `offset ${m.index}`]);
  }
  spec.others.forEach((slug, i) => {
    for (const name of nameVariants(slug))
      if (nameRegExp(name).test(text)) found.push(["project name", `project ${i + 1} of the dashboard`]);
  });
  spec.groups.forEach((g, i) =>
    nameVariants(g).forEach((n) => nameRegExp(n).test(text) && found.push(["group name", `group ${i + 1}`])),
  );
  for (const real of Object.keys(spec.own))
    for (const n of nameVariants(real))
      if (n !== "busyyaks" && nameRegExp(n).test(text)) found.push(["project name", "busyyaks' own working slug"]);
  return found;
}

if (typeof module !== "undefined")
  module.exports = { makeRenamer, leaks, specFrom, mergedRepos, nameRegExp, nameVariants, hostsIn, KEPT_HOSTS };
