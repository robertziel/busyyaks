# Contributing to busyyaks

Issues and pull requests are welcome. By contributing you agree that your contribution is licensed under the
project's [Apache License 2.0](LICENSE) (its section 5), and that you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
A security problem goes to [SECURITY.md](SECURITY.md), never to a public issue.

## Setup

Everything runs in Docker; install nothing on the host but git and Docker.

```bash
git clone https://github.com/robertziel/busyyaks && cd busyyaks
# the pre-commit hook: overcommit in Docker (RuboCop, ESLint, Prettier, gitleaks, ShellCheck on the staged files)
git config core.hooksPath .githooks
# sign the hook config: once per clone and per worktree, and after every change to .overcommit.yml or a hook script
scripts/hooks/run sign
```

`.overcommit.yml` is signed: until `scripts/hooks/run sign` has run in this worktree, every commit is refused. Read a
changed `.overcommit.yml` (or `scripts/hooks/*`) before you sign it; signing is what says you reviewed it. Details:
[`docs/LINT.md`](docs/LINT.md).

To run the app itself, follow the [Quickstart](README.md#quickstart).

## Tests

```bash
scripts/ci/test.sh all       # lint · ruby · frontend · audit · secrets — what CI runs; needs only Docker
scripts/ci/test.sh ruby      # one stage: lint | ruby | frontend | audit | secrets
scripts/lint/rubocop -a      # RuboCop autocorrect
```

A pull request is reviewed once `scripts/ci/test.sh all` is green. Stages, parallelism and coverage floors:
[`docs/TESTING.md`](docs/TESTING.md).

## Rules for a change

- **Never exclude a check to make it pass.** A failing test, lint cop, type check, advisory or secrets finding is
  fixed in the code. Not accepted: `skip`, `.only`, a `# rubocop:disable` or `eslint-disable`, `@ts-ignore`, a todo /
  baseline / allowlist file, a per-file `Exclude:`, a raised limit or lowered coverage floor, `--no-verify`, `|| true`
  on a gate, a deleted or pending test. A rule that is wrong for the project is changed in its config for everyone,
  with the reason next to it.
- **The kanban module is vendored; change it at its source.** `vendor/agents_kanban/` and
  `frontend/src/vendor/agents_kanban/` are copies of
  [busyyaks_agents_kanban_module](https://github.com/robertziel/busyyaks_agents_kanban_module). An engine change
  (board, cards, MCP `kanban_*` tools, notifier, launch rules, the React board) is a pull request to that repo first,
  with its tests; once it is merged, busyyaks re-vendors the new commit with
  `KANBAN_ENGINE=<checkout> scripts/vendor-kanban-engine.sh`, which refuses to overwrite a copy that was edited in
  place. A busyyaks PR that edits the vendored files directly is not merged.
- **No fallbacks.** When something required is missing or unreachable, fail loudly with the reason: boot refuses a
  missing env or config key, a failed read is recorded and shown. Never substitute a default, a cached value or a
  guess.
- **A deployment is configuration, never code.** No host, IP, domain, port, path or model name in code, compose,
  tests or examples: per-deployment values go in `.env` (documented in `.env.example`) or `config/*.yml` (documented
  in the `*.example.yml` files), one place per value.
- **Tests with the change.** A fix comes with the test that fails without it; a feature with tests for what it does
  and what it refuses.
- **Docs with the change.** Update the README, `docs/` and the example config in the same pull request, and add a line
  under `Unreleased` in [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.

## Commits and pull requests

- One logical change per commit and per pull request; the history is rebased, not merged.
- Subject: imperative, at most ~72 characters, saying what changes for the user (`Board: refuse a move with no
  transition`), optionally prefixed with the area. The body says why, and what was measured or tested.
- Sign-off and GPG signatures are welcome, not required.
- A pull request fills in the [template](.github/PULL_REQUEST_TEMPLATE.md): what and why, how it was tested, the
  screenshots of any visible change (desktop and phone width, light and dark skin when the colours change).
