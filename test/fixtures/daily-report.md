```tl:stats
- { label: Commits 24h, value: 38, prev: 14, good: up, tone: accent, sub: 31 mine · 5 repos }
- { label: Repos active, value: 5, prev: 3, good: up }
- { label: Uncommitted, value: 17, prev: 23, good: down, tone: warn, sub: "acme/shop 12 · acme/auth 5" }
- { label: Unpushed, value: 11, prev: 4, good: down, tone: warn, sub: "acme/site 8 · acme/auth 3" }
- { label: No upstream, value: 1, tone: bad, sub: 9 commits on this box only }
- { label: Human Check, value: 1, tone: warn, sub: 24 scanned · 0 errors }
```

```tl:callout
tone: bad
title: 9 commits exist only on this box — acme/shop has no remote
```

## Needs you

`warn:1 card in Human Check`

```tl:needs
- { title: Check the new checkout page, repo: acme/shop, ask: "card in Human Check: PR open, CI green" }
- { title: Approve the orders migration before deploy, repo: acme/api, ask: "`20260114120000` makes `orders.currency` required; old clients fail" }
```

## At risk

```tl:flags
- { level: bad, kind: no upstream, repo: acme/shop, text: "9 commits + 12 dirty files on `feat/checkout`" }
- { level: warn, kind: breaking, repo: acme/api, sha: 3f2a9c1e, text: "`orders.currency` required; migration `20260114120000`" }
- { level: warn, kind: unpushed, repo: acme/site, text: "8 commits ahead of `origin/main`" }
- { level: warn, kind: unpushed, repo: acme/auth, sha: 7b1d04aa, text: "3 commits + 5 dirty" }
- { level: info, kind: security, repo: acme/api, sha: 5c0e8f12, text: "Hardcoded test key removed before it reached the remote" }
```

## Shipped

```tl:cards
- repo: acme/shop
  status: bad
  branch: feat/checkout
  upstream: false
  commits: 9
  prev: 0
  dirty: 12
  files: 64
  add: 3120
  del: 410
  shipped:
    - "One-page checkout"
    - "Cart persisted across devices"
  risks:
    - "No remote: 9 commits on this box only"
    - "Uncommitted: payment form, `cart_store.ts`"
  shas: [a1b2c3d4, e5f6a7b8]
- repo: acme/api
  status: warn
  branch: main
  upstream: true
  commits: 14
  prev: 6
  unpushed: 0
  files: 41
  add: 1875
  del: 602
  shipped:
    - "Orders carry a currency"
    - "Rate limit per API key"
    - "OpenAPI spec regenerated"
  risks:
    - "**Breaking:** `orders.currency` required"
  shas: [3f2a9c1e, 5c0e8f12, 9d8c7b6a]
- repo: acme/site
  status: warn
  branch: main
  upstream: true
  commits: 8
  prev: 5
  unpushed: 8
  files: 10
  add: 940
  del: 35
  shipped:
    - "Pricing page"
    - "`/blog` feed"
  shas: [0f1e2d3c]
- repo: acme/auth
  status: warn
  branch: main
  upstream: true
  commits: 3
  prev: 0
  dirty: 5
  unpushed: 3
  files: 4
  add: 88
  del: 12
  shipped:
    - "Session lifetime configurable"
  risks:
    - "Uncommitted: login template, `app.rb`"
  shas: [7b1d04aa]
- repo: acme/infra
  status: ok
  branch: main
  upstream: true
  commits: 4
  prev: 3
  unpushed: 0
  files: 6
  add: 120
  del: 44
  shipped:
    - "Nightly backup verified by restore"
  shas: [6e5d4c3b]
```

## Changes

```tl:churn
- { repo: acme/shop, files: 64, add: 3120, del: 410, top: [frontend, app, spec] }
- { repo: acme/api, files: 41, add: 1875, del: 602, top: [app, db, docs] }
- { repo: acme/site, files: 10, add: 940, del: 35, top: [src] }
- { repo: acme/infra, files: 6, add: 120, del: 44, top: [ansible] }
- { repo: acme/auth, files: 4, add: 88, del: 12, top: [lib, config] }
```

```tl:spark
- { label: Commits/day 7d, values: [22, 9, 31, 17, 26, 14, 38], tone: accent }
- { label: Mine/day 7d, values: [18, 7, 25, 12, 20, 11, 31], tone: ok }
```

## Upstream

`info:0 upstream commits in 24h`

## GitHub network

```tl:github
window: 1d
to: '2026-01-15T07:00:00+01:00'
collected: '2026-01-15T06:58:00+01:00'
follows_since: '2026-01-01T09:00:00+01:00'
network:
  octocat: https://avatars.githubusercontent.com/u/583231?v=4
  defunkt: https://avatars.githubusercontent.com/u/2?v=4
repos:
- repo: octocat/hello-world
  description: My first repository on GitHub
  language: Ruby
  stars: 120
  topics:
  - example
  avatar: https://avatars.githubusercontent.com/u/583231?v=4
  starred_by:
  - defunkt
  starred_at: '2026-01-14T18:20:00+01:00'
```

## Act on

```tl:actions
- { priority: high, repo: acme/shop, text: "Add a remote, push `feat/checkout`; triage 12 dirty" }
- { priority: high, repo: acme/api, text: "Approve the `orders.currency` migration before deploy" }
- { priority: med, repo: acme/site, text: "Push 8 commits" }
- { priority: med, repo: acme/auth, text: "Commit login template + `app.rb`, push 3" }
```

```tl:kv
Window: 2026-01-14 07:00 → 2026-01-15 07:00
Commits, no upstream: commit log + git (read-only)
Dirty, unpushed: scan at report time
Prev: commits = the 24h before; Uncommitted / Unpushed = previous report
```
