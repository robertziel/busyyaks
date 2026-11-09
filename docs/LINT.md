# Lint — RuboCop with Cookpad's style guide, git hooks via overcommit

| | |
|---|---|
| Rules | [Cookpad's Ruby style guide](https://github.com/cookpad/styleguide/blob/master/ruby.en.md) — its `rubocop.yml` copied **verbatim** to `config/rubocop/cookpad.yml` (CC BY 3.0, source sha in the header). `DisabledByDefault: true`: only the cops the guide names run. Max line 128 |
| Repo settings | `.rubocop.yml`: inherits the Cookpad file, Ruby 3.4, excludes `data/ frontend/ log/ tmp/ public/` (Cookpad's own: `vendor/ db/ bin/ node_modules/`) |
| No exemptions | no todo file, no `rubocop:disable`, no per-file `Exclude`, no raised `Max`. The whole tree has 0 offenses; a new offense is fixed in the code, never exempted (the same for `eslint-disable` in busyyaks' own frontend code) |
| Version | `rubocop 1.92.2` in the Gemfile's `:lint` group (pinned in `Gemfile.lock`) |
| Plugins | `rubocop-performance 1.27.0` · `rubocop-rake 0.7.1` · `rubocop-sequel 0.4.1` · `rubocop-thread_safety 0.8.0` (`:lint` group), each department enabled whole in `.rubocop.yml` (Cookpad's `DisabledByDefault` would leave them off; pending cops stay off, `NewCops: disable`). One cop off for everyone: `ThreadSafety/NewThread` (no job framework to hand threads to; the deliberate service threads are bin/github's poller and bin/launcher's clone waiter + socket server — reason in `.rubocop.yml`). Class-level memos are `Mutex`/`Monitor#synchronize`-guarded |
| Run | `scripts/lint/rubocop [args]` — Docker only; image `busyyaks:lint-<hash of Gemfile, Gemfile.lock, scripts/lint/Dockerfile>`, built on first use from those three files. `-a` autocorrects in place |
| Pre-commit | [overcommit](https://github.com/sds/overcommit) 0.75.0 (`:lint` group), config `.overcommit.yml` — RuboCop on the staged Ruby files, ESLint on the staged `frontend/` TS/TSX, Prettier `--check` on the staged TS/TSX/JS/CSS/JSON, gitleaks on the staged changes, ShellCheck on the staged shell scripts, plus overcommit's default pre-commit hooks; all in Docker (§ Git hooks) |
| ESLint (frontend) | `frontend/eslint.config.js` = typescript-eslint 8 `recommendedTypeChecked` (`projectService: true`) + eslint-plugin-react-hooks 5, over all of `frontend/src` **including `src/vendor/`** (the engine passes the same config at its source and is re-vendored); `noInlineConfig` (an `eslint-disable` comment has no effect and is itself a warning), `--max-warnings 0 --report-unused-disable-directives`, only `node_modules/` ignored; `npm run lint` in Docker, CI `scripts/ci/test.sh frontend` |
| Prettier | Prettier 3.9.10 (exact devDependency in `frontend/package.json`), `.prettierrc.json` = `printWidth: 120`, the rest Prettier's defaults; `.editorconfig` (utf-8, LF, final newline, 2-space indent; Prettier reads it too). Every TS/TSX/JS/CSS/JSON file in the repo — `frontend/` (incl. `src/vendor/`, which passes because the engine is formatted at its source with the same config), `public/static/*.{css,js}`, `vendor/agents_kanban/fixtures/` (same). `.prettierignore` = `package-lock.json` (npm writes it) + `public/app/` (Vite's build output); Prettier also reads `.gitignore`. Markdown and YAML are not formatted. No `eslint-config-prettier`: `recommendedTypeChecked` + react-hooks carry no stylistic rules, ESLint stays 0. Run: `npm run format:check` / `npm run format` in `frontend/` (Docker; both `cd ..` = the repo root); CI `scripts/ci/test.sh frontend` |
| ShellCheck | `koalaman/shellcheck:v0.10.0`, `--severity=style` (every finding fails, notes included) on **every shell script, found by shebang** (`scripts/lint/shell-files`: `#!/bin/sh`, `#!/bin/bash`, `#!/usr/bin/env bash` — most have no `.sh`: `bin/*`, `.githooks/*`, `scripts/hooks/*`, `scripts/lint/*`). `.shellcheckrc` disables nothing: `external-sources=true` + `source-path=SCRIPTDIR` only say where sourced files are — `bin/daily-report` and `deploy/install-daily-timer.sh` source the gitignored `.env`, so their `# shellcheck source=../.env.example` points ShellCheck at the committed file with the same keys. No `# shellcheck disable`. Run: `scripts/lint/shellcheck` (Docker) |
| CI | `scripts/ci/test.sh lint` (Jenkins stage `Lint`, part of `jenkins/ci`): RuboCop, then ShellCheck — the whole tree, so `--no-verify` gains nothing |

## Git hooks (overcommit, in Docker)

`.githooks/pre-commit` is one line: `scripts/hooks/run pre-commit`, which runs overcommit inside the
`busyyaks:hooks-<hash>` image (`scripts/hooks/Dockerfile`; `scripts/hooks/image` tags it by the hash of every input
and builds it on first use). The host needs only git and docker — no Ruby, no gems, no node.

| | |
|---|---|
| Image | `ruby:3.4-slim` + the Gemfile's `:lint` group (overcommit, RuboCop + plugins, as `Gemfile.lock` pins them: the CI lint stage's gems) · node 22 + `npm ci` of `frontend/package-lock.json` (CI's frontend packages) · gitleaks v8.30.1 (CI's secrets stage version) |
| What it checks | the **staged** tree: the container gets the git dir and a copy of the index, checks the index out into a tmpfs and runs overcommit there. The working tree is never mounted — a hook cannot edit a file, and overcommit never has to `git stash` unstaged changes (the stash stack is shared by every worktree) |
| `RuboCop` | overcommit's built-in hook, `.rubocop.yml`, `--force-exclusion`; any offense, convention level included (`on_warn: fail`), anywhere in a staged file |
| `EsLintFrontend` | ad hoc hook `scripts/hooks/eslint frontend`: `eslint --max-warnings 0 --report-unused-disable-directives` on the staged `*.ts *.tsx` under `frontend/`, run in the staged `frontend/` with its `eslint.config.js` (type-aware: it sees the whole staged project) |
| `PrettierCheck` | ad hoc hook `scripts/hooks/prettier`: `prettier --check` on the staged `*.{ts,tsx,js,css,json}`, at the root of the staged tree (`.prettierrc.json`, `.prettierignore`, `.gitignore`) |
| `Gitleaks` | ad hoc hook `scripts/hooks/gitleaks`: `gitleaks git --pre-commit --staged --ignore-gitleaks-allow`, default rules; an in-repo `.gitleaks.toml` / `.gitleaksignore` is refused, as in CI |
| `ShellCheck` | overcommit's built-in hook, `command` = `scripts/hooks/shellcheck` (in the image as `/hooks/shellcheck`; ShellCheck v0.10.0 copied from CI's image): `include: '**/*'`, the wrapper keeps the staged files `scripts/lint/shell-files` calls shell scripts and runs `shellcheck --format=gcc --severity=style` on them in the staged snapshot |
| Defaults | overcommit's own default pre-commit hooks stay on: AuthorName, AuthorEmail (the host's `git var GIT_AUTHOR_IDENT`), BrokenSymlinks, CaseConflicts, MergeConflicts |
| Signed | `verify_signatures: true`. The signature of `.overcommit.yml` (and of each ad hoc hook) lives in each worktree's own config (`config.worktree`; `extensions.worktreeConfig`, set in the repo's config by `sign` — § Per worktree); a new clone, or any change to the file (in that worktree), refuses every commit until a person reviews it and runs `scripts/hooks/run sign` (= `overcommit --sign` + `overcommit --sign pre-commit`, in the image, on the **staged** file — stage it first) |
| Per worktree | the signatures live in the worktree's own config (`$GIT_DIR/config.worktree`, `git config --worktree`), so worktrees on branches with different `.overcommit.yml` never re-lock each other: overcommit 0.75.0 uses `--worktree` when `extensions.worktreeConfig` is on (else `--local`, shared by every worktree). `scripts/hooks/run sign` turns the extension on (`git config --local extensions.worktreeConfig true`, once per clone); a hook with it off in the repo's own config is refused (git ignores a global or system value). `git worktree add` copies the worktree's `config.worktree` into the new one, so a new worktree starts with the signatures of the worktree it was added from: its commits pass only while its `.overcommit.yml` (and ad hoc hooks) hash the same, a differing one is refused until it signs, and one added from an unsigned worktree is refused. Signatures a clone recorded in its shared config before the extension (`git config --local --get-regexp '^overcommit\.'`) are no longer read: sign each worktree again, then drop them (`git config --local --remove-section overcommit.configuration`, and each `overcommit.PreCommit.<hook>`) |
| No way around | no docker / no daemon / an image that does not build → the commit is refused, nothing skipped. The caller's environment is not passed in, so `SKIP=`, `ONLY=`, `OVERCOMMIT_DISABLE`, `OVERCOMMIT_NO_VERIFY` have no effect. CI runs every check on the whole tree regardless |
| Wired | pre-commit only. `commit-msg` and `pre-push` are not routed to overcommit: on a machine with a global `core.hooksPath` the global `pre-push` (e.g. a private local-repo leak gate) stays the only pre-push hook |

## Enable the hook

- Plain clone: `git config core.hooksPath .githooks`
- A machine with a global `core.hooksPath` (git then ignores the repo's hooks): a global `pre-commit` that runs the
  repo's own one —
  ```sh
  #!/usr/bin/env bash
  hook="$(git rev-parse --show-toplevel)/.githooks/pre-commit"
  [ -x "$hook" ] && exec "$hook" "$@"
  exit 0
  ```
  Every commit in the repo runs it, an agent's included.
- Then, once per worktree (the clone's own checkout included): `scripts/hooks/run sign` (after reading `.overcommit.yml`).

## Quality tools

What runs where. CI = a stage of `scripts/ci/test.sh` (Jenkins `jenkins/ci`), on the whole tree; pre-commit = an
overcommit hook, on the staged files.

| tool | checks | CI stage | pre-commit |
|---|---|---|---|
| RuboCop 1.92.2 + rubocop-performance, -rake, -sequel, -thread_safety | Ruby style (Cookpad), performance, Rakefile, Sequel and thread-safety cops | `lint` | `RuboCop` |
| ESLint 9: typescript-eslint `recommendedTypeChecked` + react-hooks 5 | TS/TSX: type-aware rules (unhandled promises, unsafe `any`), hooks rules | `frontend` (with `tsc --noEmit`, vitest) | `EsLintFrontend` |
| gitleaks v8.30.1 | secrets | `secrets` (full git history) | `Gitleaks` (staged changes) |
| bundle-audit + npm audit | known advisories in `Gemfile.lock`, `frontend/package-lock.json` | `audit` | — (network, advisory DBs) |
| ShellCheck v0.10.0 | shell scripts (by shebang), `-S style` | `lint` | `ShellCheck` |
| Prettier 3.9.10 + `.editorconfig` | TS/TSX/JS/CSS/JSON formatting, the whole repo (vendored engine included) | `frontend` | `PrettierCheck` |
| SimpleCov | Ruby line + branch coverage minimum | coming, inside `ruby` | — |

### Considered and not used

| tool | why not |
|---|---|
| rubocop-minitest | ~95% of its findings are `Minitest/MultipleAssertions`; the suite asserts many facts per scenario on purpose, and switching that cop off would be an exclusion |
| hadolint | its only finding is DL3008 (pin apt package versions); pinned Debian versions break builds when the Debian archive drops one, so the rule would be disabled = an excluded check |
| yamllint | nearly all findings are `line-length` and `braces` (compose's flow mappings): style choices made on purpose — adopting means reflowing every file or disabling the rule |
| markdownlint | nearly all findings are `line-length`: the same style choice as yamllint |
| knip | flags the engine's public API (`index.ts` exports used outside the repo) as unused |
| Brakeman | sees 0 controllers on Hanami (a Rails scanner) |
| Sorbet / Steep | Hanami 2.3 / Sequel type signatures too thin; weeks of work |

