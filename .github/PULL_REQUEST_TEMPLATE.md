<!-- Read CONTRIBUTING.md first. A security fix: report it privately (SECURITY.md) before opening a PR. -->

## What and why

<!-- What changes for a user or an operator, and why. Link the issue: Fixes #… -->

## How it was tested

<!-- The tests added or changed, and anything run by hand. -->

- [ ] `scripts/ci/test.sh all` is green (lint · ruby · frontend · audit · secrets)
- [ ] a test that fails without this change (fix) or covers what it does and refuses (feature)
- [ ] no check excluded, skipped, disabled or loosened to pass
- [ ] no edit under `vendor/agents_kanban/` or `frontend/src/vendor/agents_kanban/` (module changes go to
      busyyaks_agents_kanban_module first, then are re-vendored)
- [ ] no deployment value (host, port, path, model) in code, compose, tests or examples
- [ ] README, `docs/`, example config and `CHANGELOG.md` (`Unreleased`) updated where users would notice

## Screenshots

<!-- Any visible change: before and after, desktop and phone width. Otherwise: "no UI change". -->
