<!-- Read CONTRIBUTING.md first. A security fix: report it privately (SECURITY.md) before opening a PR. -->

## What

<!-- 1-3 short sentences: what changes for a user or an operator. Link the issue: Fixes #… -->

## Why

<!-- The real case behind it: what someone did and what went wrong. A security fix: the advisory. -->

## Verified

<!-- At this head: what ran, where (tests, a running stack), and the result. -->

- Not verified: <!-- what, and why; or "nothing" -->

- [ ] `scripts/ci/test.sh all` is green (lint · ruby · ruby-pg · frontend · flake · audit · secrets · host; the env it
      needs: CONTRIBUTING.md § Tests)
- [ ] a test that fails without this change (fix) or covers what it does and refuses (feature)
- [ ] no check excluded, skipped, disabled or loosened to pass
- [ ] no edit under `vendor/agents_kanban/` or `frontend/src/vendor/agents_kanban/` (module changes go to
      busyyaks_agents_kanban_module first, then are re-vendored)
- [ ] no deployment value (host, port, path, model) in code, compose, tests or examples
- [ ] README, `docs/`, example config and `CHANGELOG.md` (`Unreleased`) updated where users would notice

## Visual

<!-- Only if it helps: a visible change before and after (desktop and phone width), a mermaid diagram or a benchmark
     table. Pictures come from a demo or test stack, never from a live deployment: they show its hosts, people and
     data. No video. Nothing visual: delete this section. -->
