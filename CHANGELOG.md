# Changelog

One line per change a user would notice. Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/);
versions: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A board card whose agent is working (thinking, running a tool, writing, waiting on its subagents) glows blue, read from the same screen evidence as the live agent line; no glow when idle, without evidence or when the agents read failed (the board says why); a card that needs you stays red. `GET /api/projects/*slug/board/live` answers the whole board from one shared agents snapshot. Colour: skin token `--working` (`--ak-working` in `config/kanban.yml` theme).
- CI checks for the approval gate: only each repo's required contexts gate (`ci.required`, the rest informational); a check pending past `ci.max_pending_minutes` turns red as stuck and pings the owner once; every page of checks is read; one bad PR no longer stops the others; a handoff's build URL must be the head's; `/github` names enrolled repos missing from `ci.required`.
- Agent faces: every agent wears two eyes on a disc in its type's colour (`config/kanban.yml` theme `--ak-face-type-<type>`; `face_roles` colours subagent roles such as `reviewer-*`, `qa-*`), its mood from the live session — in comments, card faces, the project's tmux list and the Agents sidebar. A person shows their picture from `avatar_url` (an https template with the email's SHA-256, e.g. Gravatar with `d=404`; its origin joins the CSP `img-src`), else the initials.
- Who is at work on a card now: `GET /api/cards/:id/live` adds `present`; `GET /api/projects/*slug/board/presence` returns it for every card, and the board shows those faces on the card faces. `/api/agents` adds `agent`, `agent_type` and `phase` to each session.
- Every PR assigned to a card is watched: one closed without merging alarms the card and pings its owner once, with the reason (base deleted · head deleted · closed by a person); its PR tag says it (`closed: base deleted`) and the approval gate refuses with it.
- An agent session's live terminal in the dashboard: **Open terminal** in the Agents sidebar and a **Terminals** section on a card (one tab per agent session working on it). Read-only until **Take control**; every open, take and release is logged on the session's cards. See `docs/DEPLOY.md` § Terminals.

### Changed

- **Breaking:** the boot refuses a `config/kanban.yml` `theme` that leaves out any `--ak-*` token the vendored engine's CSS declares, naming each; add `--ak-working: var(--working)` and `--ak-step-overhang: 12px` (see `docs/DEPLOY.md` § The board theme).
- **Breaking:** required `config/busyyaks.yml` `ci` (`max_pending_minutes: 1..1440`, `required: {owner/name: [contexts]}`); see `docs/DEPLOY.md` § CI checks.
- **Breaking:** required `config/busyyaks.yml` `terminal` (`public_host: allow | deny`, `max_open: 1..64`); see `docs/DEPLOY.md` § Terminals.
- **Breaking:** required `config/kanban.yml` `face_roles` and `avatar_url` (null allowed; boot refuses a config without them); copy them and the `--ak-face-type-*` theme colours from `config/kanban.example.yml`.
- CI runs `ruby`, `ruby-pg`, `frontend` and the new `flake` stage on the public runner's CPU count (`scripts/ci/runner.env`) as a Docker CPU quota. `flake` runs each test file a change touches `CI_FLAKE_REPEATS` times, in batches of `CI_RUNNER_CPUS` runs: a changed test file, and the tests that name a changed `lib/`, `bin/` or `cli/` file. Any other changed path (e.g. `CHANGELOG.md`, docs, config) or a deleted one repeats the whole suite; an integration test that reaches a lib file only through the app is repeated only then.
- Code reads the time only through `Busyyaks::Clock`; a test stubs it, and never sleeps or waits with a timeout itself (`test/support/wait.rb`, `test/unit/no_real_clock_test.rb`).
- CI audits `main` daily; a red run opens the issue "Daily CI red on main".
- **Breaking:** `.env` requires `TEST_WORKERS` (every `docker compose` command reads it); `scripts/ci/test.sh audit` requires `CI_GITHUB_CACHE_DIR`.
- **Breaking:** `scripts/ci/test.sh flake` (and so `all`) requires `CI_BASE_REF`; `ruby`, `ruby-pg`, `frontend` and `flake` require a Docker host with at least `CI_RUNNER_CPUS` (4) CPUs whose daemon applies `--cpus` (a rootless dockerd needs the cpu controller delegated); see `CONTRIBUTING.md` § Tests.
- GitHub PR-state reads are conditional (an unchanged PR answers 304 and costs no rate limit); when the token's rate limit is used up, the CI-check and PR-state polling pauses until GitHub's reset, each waiting card says so, and `/github` shows each tick's calls, 304s, the limit left and the pause.

### Fixed

- A handoff or approval right after GitHub's CI was read green no longer gets refused "CI not read yet" because its request had just aged out of the poll window: a read made within the last 3 poll intervals is used as it is.

## [1.0.0-beta.2] - 2026-11-15

### Added

- First-run hello screen: boot checks, projects dir, launchers and a default.
- Settings menu in the header; launchers and agent types edited in the database; launcher kind `hermes`.
- Daily report settings edited on **Settings → Daily report**.
- PRs are assigned to cards explicitly (`kanban_pr_assign`), never found by branch name or text.
- Alert when a board-started session fails to start.
- Approve buttons name the step they approve.
- `yaks` command line (`bin/yaks`, host Ruby ≥ 3.2): `server status`, `server logs`, `panel`, `env`, `doctor`.
- Board: left/right arrow click areas scroll the lists.
- Project page: the title stays pinned under the header while the page scrolls, on one line.
- Board: cards glide to their new place (agent moves, drops, filter and order changes) instead of jumping.
- Skins are files: `skins/<key>.yml` (Light, Dark and any added, e.g. Matrix), picked in the settings cog.
- Dictation: hold ⌥R / Alt+R in an open card (or click the mic) to talk a comment into the box, transcribed by the deployment's speech server (`dictation` in config/busyyaks.yml, `DICTATION_URL`); the key is picked on **Settings → Shortcuts**.
- Desktop app: `yaks desktop install --browser NAME` adds busyyaks to the app menu (Linux, the BSDs, macOS), or install it from Chrome or Edge; its own window, the icon's badge counts the cards waiting for you.
- Session boards: each agent session gets its own board, attached to no project (`kanban_session_board`), shown read-only on **Sessions**; idle boards are archived, never deleted.
- Hover a card mention (comments, the question and its option buttons, the agents rail, the waiting list, reports, notes) to see that card's details.

### Changed

- **Breaking:** launchers and agent types moved from `config/kanban.yml` to the database; migrate per `docs/DEPLOY.md` § Agent settings.
- **Breaking:** required `config/busyyaks.yml` `launch.commands`: the allowlist of whole invocations a launcher may be.
- **Breaking:** daily report settings moved from `config/busyyaks.yml` to the database; migrate per `docs/DAILY-REPORT.md` § Moving off config/busyyaks.yml.
- Daily report: a day with no runnable settings posts one `NOT CONFIGURED` report saying why; a settings change re-installs the timer at the next tick.
- **Breaking:** required `config/busyyaks.yml` `dictation` (`none`, or the speech server's model and limits) and `.env` `DICTATION_URL` / `DICTATION_TOKEN` (empty when `none`); see `docs/DEPLOY.md` § Dictation.
- Board: cards that wait for the operator are highlighted with a needs-you badge.
- Board: a dragged card near the edge scrolls the lists sideways, with edge shades.
- The operator's drag is never stuck behind the green-CI gate.
- Projects page: compact rows, sessions shown once, card layout on phones and tablets.
- Agent comments: the review header renders as a badge strip; GitHub PR / issue / commit URLs as chips.
- Links to other servers open in a new tab.
- Blocked externally no longer counts as waiting for the operator.
- PR flags read the card's assigned PR from its metadata, whatever the branch name.
- Shipped agent prompt: the QA and Reviewer subagents an agent starts run on haiku.
- README intro: your local agent agency; install and usage text updated.

### Fixed

- A link the browser cannot parse is left as written instead of blanking the card.
- Header nav fits phones: it scrolls in its own row, never the whole page sideways.
- Scan errors name an orphaned worktree by its host path and git dir.
- Launcher: a launch whose claude never comes up fails (422), the session is killed and its cards released.
- Launcher start check never refuses before `launch.start_seconds`.
- Scanner: one project per repo — linked worktrees are never projects.
- First approval step read off its own gate's handoff and approve entries.

## [1.0.0-beta.1] - 2026-11-10

First public release (SemVer pre-release: config keys, JSON API and MCP tools may still change before 1.0.0).

### Added

- **Today** page: commits, your commits, active repos, merged PRs per day; 53-week heatmap; unknown shown as `—`.
- Scanner: git log, status, upstream of every repo under the roots (read-only), failures shown beside the last good scan.
- **Projects** / project pages: branch, last commit, dirty, unpushed, notes, cards per column; create or clone a repo.
- [Backlog.md](https://github.com/MrLesk/Backlog.md) `backlog/` tasks shown on the board, read-only.
- Kanban board per repo from [busyyaks_agents_kanban_module](https://github.com/robertziel/busyyaks_agents_kanban_module): drag and drop, labels, checklists, due dates, attachments, shortcuts.
- Agents on the board: claim cards, ask the operator, flag external blockers, hand off into a gate with PR + CI + screenshots.
- Approval on green CI: gate handoff and Approve refused until the PR checks are green.
- Workflow v3: fixed column types, named transitions per board, agent review loops with counted rounds.
- Workflow graph editor, auto-laid out by [dagre](https://github.com/dagrejs/dagre).
- Launch and supervise agents in tmux from the browser (lead, worker, sub team, plain) with concurrency caps.
- Agents sidebar: every session worst first; a permission dialog becomes a question answerable from the browser.
- MCP server (HTTP, bearer token, local only): projects, commits, notes, reports, GitHub network, every `kanban_*` tool.
- Daily report written by a local LLM over MCP, every number computed and checked server-side; systemd timer.
- GitHub network: what the people you follow starred and followed, and your feed summarised.
- PR flags on cards: open / draft / merged, read from GitHub.
- Search (`⌘K`) over projects, cards, commits, reports; light and dark skins.
- Pluggable sign-in: `auth: none` for localhost or your own provider class.
- Database: SQLite (WAL, concurrent-writer safe) or PostgreSQL (`DATABASE_ADAPTER`); `bin/db-copy-sqlite-to-postgres`.
- Deployment as configuration: `.env` + `config/*.yml`, loud validation, no defaults ([docs/DEPLOY.md](docs/DEPLOY.md)).
- Quality gates: `scripts/ci/test.sh all` in Docker (RuboCop, ShellCheck, tests + coverage floor, tsc, ESLint, Prettier, vitest, audit, gitleaks); signed pre-commit hook.
- Community files: [SECURITY.md](SECURITY.md), [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [NOTICE](NOTICE).

### Security

- `auth: none` boots only with `allow_unauthenticated: true` and logs a banner on every boot.
- Session cookie always `HttpOnly`; `Secure` / `SameSite` from `.env`, validated at boot; sign-in redirects to local paths only.
- Host allowlist + Origin check against DNS rebinding.
- MCP on loopback only; refused tokens logged; any `Origin` header refused.
- Daily-report agent limited to two exact git commands in repos under the projects root.
- CI passes GitHub tokens through a pipe, never on a command line.
- Launcher socket private (umask); git `safe.directory` scoped to the mounted repos.
- Credentials stripped from stored remote URLs; Markdown rendered with raw HTML dropped.

[Unreleased]: https://github.com/robertziel/busyyaks/compare/v1.0.0-beta.2...main
[1.0.0-beta.2]: https://github.com/robertziel/busyyaks/compare/v1.0.0-beta.1...v1.0.0-beta.2
[1.0.0-beta.1]: https://github.com/robertziel/busyyaks/releases/tag/v1.0.0-beta.1
