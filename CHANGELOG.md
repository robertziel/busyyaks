# Changelog

All notable changes to busyyaks are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking for hosts)

- **Agent settings in the database**: the launchers and agent types left `config/kanban.yml` (a file that still has
  `launchers` / `agent_types` stops the boot) for table `agent_settings` (one row per saved revision, newest =
  current), edited on **Settings → Agents & launchers** (the header's new cog menu, which also holds the skin switch
  and Sign out) or with `bin/agent-settings show | import < file`. Every launcher has a `kind`: `claude_code` (as
  before) or `hermes` (Hermes Agent, no remote control). **Required:** `config/busyyaks.yml` `launch.commands`, the
  host allowlist of whole invocations `{kind, command, args, via_shell}` a launcher may be — refused on save and by
  the launcher. **Migrating:** one maintenance window, `docs/DEPLOY.md` § Agent settings.

### Changed

- **Public: Create PR** on the private local-repo boards (the engine's `local_v4` board): the operator's "Open public
  PR" moves a card from Local: Deploy check into this new column, where the agent opens the public PR, then "Public PR
  opened" moves it to Public: Agent review — no review of a PR that does not exist yet. A board is data: an existing
  board takes the new shape in the Workflow editor (or `POST /api/projects/*slug/workflow`); no migration. The approve
  button names its step ("✓ Open public PR → Public: Create PR"). The workflow graph folds for the box height too, so
  the 15-column board shows whole at 1920 × 1080.

## [1.0.0-beta.1] - 2026-11-10

Everything below ships as **1.0.0-beta.1**, the first public release: one self-hosted panel over every git repo on a
Linux box and the coding agents working them. A beta (a SemVer pre-release): the configuration keys, the JSON API and
the MCP tools may still change before 1.0.0, each change recorded here.

### Added

- **Today** page: commits, your commits, active repos and your merged pull requests per day over `window_days`, a
  53-week contribution heatmap, tracked / uncommitted / unpushed counts and the last scan. Unknown values are shown as
  `—`, never 0.
- **Scanner**: reads git log, status and upstream of every repo under the configured roots (mounted read-only) on an
  interval; failures are recorded and shown next to the last good scan.
- **Projects** and **project** pages: branch, last commit, window commits, dirty and unpushed state, notes, cards per
  column; create or clone a repo from the browser. A [Backlog.md](https://github.com/MrLesk/Backlog.md) `backlog/`
  folder is shown on the board, read-only.
- **Kanban board per repo**, from the vendored [busyyaks_agents_kanban_module](https://github.com/robertziel/busyyaks_agents_kanban_module):
  drag and drop, labels, checklists, due dates, covers, attachments, Markdown comments, keyboard shortcuts; the board's
  columns, column types and transitions are edited in a workflow graph and kept in the database.
- **Agents on the board**: Claude Code sessions claim cards, ask the operator a question (the card is flagged
  `needs_operator` where it sits) or flag an external blocker, and hand work over into a gate with the PR, the CI build
  and screenshots; only the operator approves, and an agent never merges before that.
- **Approval on green CI**: a gate is handed off only once its PR checks are green, the checks of every gate card are
  read ahead (conditional requests, no rate limit spent on an unchanged PR), and Approve is refused on commits pushed
  after the handoff; "waiting for you" counts only the cards Approve would pass now, red CI pings the owner.
- **Workflow v3**: a fixed set of column types (`parked`, `queued`, `working`, `review`, `gate`, `done`, `cancelled`)
  that carry every rule; named transitions per board; agent review loops with review rounds counted per column;
  stored boards migrated on upgrade.
- **Workflow graph editor**: the whole board on screen, laid out automatically by
  [dagre](https://github.com/dagrejs/dagre) (no stored positions); add, rename, retype and connect columns.
- **Launch and supervise agents** in tmux from the browser (lead, worker, sub team, plain), with concurrency caps per
  type and project; every session is started with Claude Code Remote Control.
- **Agents sidebar**: every agent session by project, worst first (blocked, review, working, finished, idle), read from
  what the pane shows; a permission dialog in a session becomes a question on its card and can be answered from the
  browser.
- **MCP server** (streamable HTTP, bearer token, local only): projects, commits, notes, reports, the daily-report facts,
  the GitHub network and every `kanban_*` tool.
- **Daily report** written by a local LLM through the same MCP tools, with every number computed by the server and
  checked before it is posted; a systemd user timer runs it.
- **GitHub network**: what the people you follow starred and whom they followed, and your github.com feed summarised,
  read with conditional requests.
- **Pull request flags** on cards: each linked PR's state (open, draft, merged) read from GitHub.
- **Search** over projects, cards, commits and reports (`⌘K`); light and dark skins.
- **Pluggable sign-in**: `auth: none` for localhost, or your own provider class; the shipped example is `none`.
- **Database**: SQLite (WAL, a stated busy timeout, immediate transactions, safe under concurrent writers) or
  PostgreSQL (`DATABASE_ADAPTER`, required; an optional compose `postgres` profile and a verified SQLite → PostgreSQL
  copy, `bin/db-copy-sqlite-to-postgres`).
- **Deployment as configuration**: `.env` and `config/*.yml` with loud validation and no defaults; localhost, nginx +
  TLS, or a tunnel ([docs/DEPLOY.md](docs/DEPLOY.md)). A generic `config/kanban.example.yml`: one plain `claude`
  launcher, Claude Code's default permission mode, no model names, prompts that name no board's columns.
- **Quality gates**: `scripts/ci/test.sh all` (RuboCop with Cookpad's style guide, ShellCheck, the Ruby suite with a
  coverage floor, TypeScript, ESLint, Prettier, vitest, dependency audit, gitleaks), in Docker on every CPU; a signed
  overcommit pre-commit hook running the same checks on staged files. GitHub Actions runs the same `all` on the
  public repo.
- Community files: [SECURITY.md](SECURITY.md), [CONTRIBUTING.md](CONTRIBUTING.md),
  [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), issue and pull request templates, and [NOTICE](NOTICE) with the
  third-party attributions.

### Security

- `auth: { provider: none }` boots only with the explicit `allow_unauthenticated: true` and logs a banner on every
  boot; the session cookie is always `HttpOnly`, its `Secure` and `SameSite` set in `.env` and validated at boot;
  sign-in redirects only to a validated local path.
- The MCP port is published on a loopback address only (`MCP_HOST` validated); every refused bearer token is logged;
  any `Origin` header is refused.
- The daily report's agent runs exactly two git commands, matched byte for byte (`log`, `status` with repo-config
  programs off) in a repo under the projects root; anything else is refused.
- CI passes GitHub tokens to `curl` through a pipe, never on its command line.
- The launcher socket is created private (umask); git's `safe.directory` is scoped to the mounted repos.
- Credentials in git remote URLs are stripped before they are stored; report and card Markdown is rendered with raw
  HTML dropped.

[Unreleased]: https://github.com/robertziel/busyyaks/commits/main
[1.0.0-beta.1]: https://github.com/robertziel/busyyaks/releases/tag/v1.0.0-beta.1
