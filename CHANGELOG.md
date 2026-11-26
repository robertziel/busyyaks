# Changelog

One line per change a user would notice. Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/);
versions: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Board card faces: a small tag beside the assignee's face says what its agent is doing now — thinking / the tool it runs and for how long, `needs you` when it is stopped on a dialog, and while it is idle what the card waits for (`waiting for your answer`, `waiting for CI`, `blocked externally`, `waiting for you`), else `idle`; `not running` when its session is gone.
- Card dialog: the comment box stays at the bottom of the card while it scrolls, so writing a comment needs no scrolling; a long draft scrolls inside the box, and a "Write a comment" button (keyboard focus, top of the card) jumps to it.
- Comment actions: a card's comment box offers **Comment** (pings the owner, no move) and one **Comment & <transition> → <column>** button per workflow transition marked `comment: true` out of the card's column — the comment is posted and the card moved in one step. Marked per transition in the board (`.busyyaks/workflow.yml` or the Workflow editor's "Comment action" checkbox), never in code.
- Tab alert: a card that starts waiting for you (a question or a gate) while busyyaks is not in front of you puts `(N new)` in the tab title and a dot on the favicon, and sets the page's theme colour; looking at the tab clears them, even while the card still waits.
- Priority orders the work on our side: a card's priority (high → medium → low → none, then the oldest) decides which card a lead adopts and hands a worker first, which ping a session is typed first, and the merge order — the **approved queue** of the cards approved into one column (e.g. Awaiting merge), shown on the card face as "⇅ queue n/m" and named in the approve ping. Order only: nothing is refused for it.

### Fixed

- Approve: a card whose pull request GitHub is still checking for conflicts (`mergeable: computing`, for a minute or two after any merge into its base) is approved instead of refused with 422; a conflict GitHub finds after the Approve holds the card's next step until it is rebased.
- Scanner: a repo gone from the projects directory no longer counts in the daily stats and reports — its commit and daily rows are removed (read again if it comes back); a directory the scan cannot list keeps the rows of the repos under it and is named in the scan's error.
- Project page: the session list follows started and ended sessions without a reload, and while the launcher is down it keeps the last list, dimmed, with the launcher's error.
- Folder-trust prompt: a session started in a repo busyyaks does not trust shows Claude Code's trust prompt on the page as a question with its two choices ("No, exit" / "Yes, I trust this folder"); your click moves the cursor onto the choice, checked on the screen, and presses Enter. The prompt draws its choices without numbers, so before this the session showed as blocked with nothing to press.
- Live pages (the board, the waiting widget, Today): a refresh that fails after a change is retried on the next poll and shown as "live · error" until it lands — a card moved on the server no longer stays in its old column under a green live mark.
- Projects: a repo whose HEAD is detached shows `detached @ <sha7>` (the full sha on hover, found by search) instead of an empty branch; the upgrade's migration clears every stored empty branch, and the next scan fills in the sha.
- Card tables: a link chip (commit, branch, PR) in a table cell stays one pill on one line — a commit shows its sha (the subject on hover), a long label is cut with an ellipsis, and a table wider than the card scrolls inside itself; a table written with an empty header row (`| | |`) draws no empty band above its rows.

### Changed

- Only you move a card out of Backlog: no agent takes a card out of a parked column (Backlog) or works one there, whatever the workflow says. A workflow giving agents a way out of a parked column is refused naming the transition; the upgrade's migration makes every stored board's way out (Prioritise) yours, and the writer writes each board back to its `.busyyaks/workflow.yml`. A board whose own column is typed parked for agent work (e.g. a `Waiting` column) needs that column retyped to `queued`.
- Pull request template: What · Why · Verified (with a required `Not verified:` line) · an optional Visual, above the contributor checklist.
- **Breaking:** GitHub is optional, connected on **Settings → Git hosts** instead of `.env` (GitLab coming soon); upgrading imports the old keys once ([docs/DEPLOY.md § Git hosts](docs/DEPLOY.md#git-hosts-github)).

## [0.1.0] - 2026-11-25

### Added

- Session isolation: busyyaks touches only the sessions it starts. Every session it starts is named `by_…` and proven by a launch record (its pane's pid + start time); a tmux session started by hand — any project, any harness — is never listed, typed into, answered, attached to, read or stopped, and the collector never reads its panes. Stop says "not started by busyyaks" for one.
- The board MCP reaches only a launched session: the new bearer `MCP_BOARD_TOKEN` (written by `bin/setup`) carries every `kanban_*` tool and is handed to each launched session in its own stage (Claude Code `--mcp-config`, Hermes its overlay); `MCP_TOKEN` has no board tool and no board text. Nothing busyyaks is registered user-wide.
- Agent rules in the web: **Settings → Agent rules** shows and edits every markdown busyyaks's sessions get — the core skill, each agent type's file (Team lead, Worker, Sub team), the on-demand skills (reviewer, qa, critic) and this deployment's layer — one card per file, in launch order per type, with each type's launch budget. A project's page → **Settings** edits every file of its `.busyyaks/skills/`; a project file adds to the global rules of its type or, with `mode: replace`, replaces them, and a project skill named like a global one replaces it for that project. Saves go through the writer; nothing needs installing — every launch reads the files.
- On-demand skills `qa` and `critic` (QA before a handoff; an independent critic before the operator's gate), editable like the reviewer.
- A running lead starts at once: at launch it assigns every card that is the agents' responsibility its own worker and follows up.
- When a busyyaks session ends, its systemd scope is stopped: what it left running in the background ends with it.
- `bin/setup secrets`: writes a secret a newer version adds to an existing `.env`; `yaks update` runs it before its backup.
- `CITATION.cff`: how to cite busyyaks (GitHub's "Cite this repository"); its version and date follow the newest release in this file.
- A board card whose agent is working (thinking, running a tool, writing, waiting on its subagents) glows blue, read from the same screen evidence as the live agent line; no glow when idle, without evidence or when the agents read failed (the board says why); a card that needs you stays red. `GET /api/projects/*slug/board/live` answers the whole board from one shared agents snapshot. Colour: skin token `--working` (`--ak-working` in `config/kanban.yml` theme).
- CI checks for the approval gate: only each repo's required contexts gate (`ci.required`, the rest informational); a check pending past `ci.max_pending_minutes` turns red as stuck and pings the owner once; every page of checks is read; one bad PR no longer stops the others; a handoff's build URL must be the head's; `/github` names enrolled repos missing from `ci.required`.
- Agent faces: every agent wears two eyes on a disc in its type's colour (`config/kanban.yml` theme `--ak-face-type-<type>`; `face_roles` colours subagent roles such as `reviewer-*`, `qa-*`), its mood from the live session — in comments, card faces, the project's tmux list and the Agents sidebar. A person shows their picture from `avatar_url` (an https template with the email's SHA-256, e.g. Gravatar with `d=404`; its origin joins the CSP `img-src`), else the initials.
- Who is at work on a card now: `GET /api/cards/:id/live` adds `present`; `GET /api/projects/*slug/board/presence` returns it for every card, and the board shows those faces on the card faces. `/api/agents` adds `agent`, `agent_type` and `phase` to each session.
- Every PR assigned to a card is watched: one closed without merging alarms the card and pings its owner once, with the reason (base deleted · head deleted · closed by a person); its PR tag says it (`closed: base deleted`) and the approval gate refuses with it.
- A card's PRs show their base, draft, mergeability and auto-merge: a tag `base: <ref>` when a PR is not on its side's branch, `draft`, `conflicts` · `behind` · `mergeable: computing`, `auto-merge`, with the details on hover. The approval gate refuses a PR on the wrong base, a draft, one with conflicts, one GitHub is still computing, one whose mergeable state busyyaks does not know, and one with auto-merge on; `behind` is only a warning.
- An agent session's live terminal in the dashboard: **Open terminal** in the Agents sidebar and a **Terminals** section on a card (one tab per agent session working on it). Read-only until **Take control**; every open, take and release is logged on the session's cards. See `docs/DEPLOY.md` § Terminals.
- An agent-session collector, `bin/collector` (Claude Code and Hermes panes in this user's tmux): installed with `deploy/install-collector.sh`, checked by `yaks doctor`; the Agents sidebar, dialog detection and typed card comments work without a separate program. The shipped example config uses it.
- Live agent status on a card: above the newest comment, what its agent is doing now (thinking, writing, running a tool and which, waiting for its subagents, idle), with the turn's time and tokens, read from the agent's screen; `working` when nothing on screen says more.
- Board: a card face shows its newest picture attachment.
- Attachments: mp4 and webm videos play in the card dialog and can be scrubbed; add `video/webm` to `.env` `ATTACHMENT_TYPES` to accept webm.
- Card dialog: a **Force** button beside every Approve approves without the CI check.
- Progress watch: a working or review card with no progress (no agent comment or move, no new PR head, CI result or branch tip) for `progress_watch.stale_minutes` pings its owner with the last evidence, then comments on the card, then counts as waiting for you.
- Workflow per project in `<repo>/.busyyaks/workflow.yml` (git-ignored): the board's columns and transitions are read from and written to that file by the new `writer` service; a file the board refuses is named in the board header. See `docs/DEPLOY.md` § The writer service and `.busyyaks/workflow.yml`.
- GitHub webhooks wake the PR and CI polls: `POST /api/github/hook` (HMAC-checked) makes the github service read the PRs a delivery names within seconds. See `docs/DEPLOY.md` § GitHub webhook.
- Settings → Runtime: the services' timing (scan, writer sync, GitHub and CI polls, notifier, watchdog grace) edited in the dashboard, applied without a restart. See `docs/DEPLOY.md` § Runtime settings.
- Settings → Updates and `yaks update [--main] [--check]`: check this checkout for a newer release tag or branch head and apply it (fast-forward, image build, database backup, services restarted); the settings cog shows a dot when one is available. See `docs/DEPLOY.md` § Updates.
- Setup wizard: a Skin step; the agent CLIs found on the host (Claude Code, Hermes, Codex) with their install link or the allowlist line to add; reopened from the settings cog it edits the current values.
- Skills: each session busyyaks launches gets the board workflow as skills for that launch only (busyyaks's, this deployment's and the repo's own `.busyyaks/skills/`), never installed user-wide. See README § Skills.
- Remote servers over ssh: `yaks remote add / connect / attach` reaches a busyyaks server on another machine; the desktop app opens a server chooser (`yaks desktop open`); the dashboard shows the connection's state and dims when it is down. See README § Remote.
- `yaks ci required OWNER/NAME` prints a repo's required CI checks from `ci.required`.
- Agents sidebar: a **Hide finished** toggle.
- A GitHub link label fixed at the bottom left of every page.
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

### Changed

- Only the operator's Launch makes a board's lead: `kanban_register` refuses a lead type, and no text tells a session started by hand to register itself.
- The lead agent type is labelled "Team lead" (its button "Launch team lead"); workers start only from the lead's spawn (the Launch bar no longer offers Worker). The unused Plain agent type is removed.
- Agent prompts say only who the session is; the board workflow lives in the skills alone.
- The writer replaces the old `/.busyyaks/` exclude line in every repo, so a project's `.busyyaks/skills/` can be committed with it.
- The dark skin is the default: a browser that has chosen no skin shows dark (was light); choosing Dark clears the stored choice, Light is stored. If you used Light before, pick it once in the settings cog. The installed app's window colour follows (`skins/dark.yml` `--bg`).
- "Needs you" no longer counts a gate card the operator already approved whose next step is its agent's (e.g. Awaiting merge after the final Approve, while the agent merges). It is shown apart: the board header and the Projects page say "N approved · agent on it", the card face "✓ approved · <owner> merging", the waiting widget a fourth ✓ "approved" segment (never in its total or the dock badge), `/api/waiting` lists it under `approved` (out of `total`), `/api/boards` and the board JSON count it as `approved`, the Agents sidebar row says "approved", and MCP `daily_facts` moves it from `human_check` to `approved`. A CI hold, a question for the operator or an external block wins over approved; an approved card with no owner session still waits for you.
- **Breaking:** the boot refuses a `config/kanban.yml` `theme` that leaves out any `--ak-*` token the vendored engine's CSS declares, naming each; add `--ak-working: var(--working)` and `--ak-step-overhang: 12px` (see `docs/DEPLOY.md` § The board theme).
- **Breaking:** a named `config/busyyaks.yml` `agents.collector` requires `tmux_timeout_seconds` (1..60) and `answer_timeout_seconds` (above 4 × the tmux one); `bin/launcher` refuses to start without them. See README § Agent sessions.
- **Breaking:** required `config/busyyaks.yml` `ci` (`max_pending_minutes: 1..1440`, `required: {owner/name: [contexts]}`); see `docs/DEPLOY.md` § CI checks.
- **Breaking:** required `config/busyyaks.yml` `terminal` (`public_host: allow | deny`, `max_open: 1..64`); see `docs/DEPLOY.md` § Terminals.
- **Breaking:** required `config/kanban.yml` `face_roles` and `avatar_url` (null allowed; boot refuses a config without them); copy them and the `--ak-face-type-*` theme colours from `config/kanban.example.yml`.
- CI runs `ruby`, `ruby-pg`, `frontend` and the new `flake` stage on the public runner's CPU count (`scripts/ci/runner.env`) as a Docker CPU quota. `flake` runs each test file a change touches `CI_FLAKE_REPEATS` times, in batches of `CI_RUNNER_CPUS` runs: a changed test file, and the tests that name a changed `lib/`, `bin/` or `cli/` file. Any other changed path (e.g. `CHANGELOG.md`, docs, config) or a deleted one repeats the whole suite; an integration test that reaches a lib file only through the app is repeated only then.
- Code reads the time only through `Busyyaks::Clock`; a test stubs it, and never sleeps or waits with a timeout itself (`test/support/wait.rb`, `test/unit/no_real_clock_test.rb`).
- CI audits `main` daily; a red run opens the issue "Daily CI red on main".
- **Breaking:** `.env` requires `TEST_WORKERS` (every `docker compose` command reads it); `scripts/ci/test.sh audit` requires `CI_GITHUB_READ_TOKEN` and `CI_GITHUB_CACHE_DIR`.
- **Breaking:** `scripts/ci/test.sh flake` (and so `all`) requires `CI_BASE_REF`; `ruby`, `ruby-pg`, `frontend` and `flake` require a Docker host with at least `CI_RUNNER_CPUS` (4) CPUs whose daemon applies `--cpus` (a rootless dockerd needs the cpu controller delegated); see `CONTRIBUTING.md` § Tests.
- GitHub PR-state reads are conditional (an unchanged PR answers 304 and costs no rate limit); when the token's rate limit is used up, the CI-check and PR-state polling pauses until GitHub's reset, each waiting card says so, and `/github` shows each tick's calls, 304s, the limit left and the pause.
- **Lead-first boards:** a board starts with its lead (the Launch button, never automatic) and only the lead starts its workers and sub team; busyyaks starts no session on its own and never relaunches a dead lead — the board says "no lead: press Launch" and an alert names the lead's end. Each session runs in its own systemd user scope. See `docs/DEPLOY.md` § Lead-first boards: upgrading a deployment.
- A card's PRs are a list, any number per role and repo: `kanban_pr_assign` adds, `kanban_pr_unassign` (or the × on the card's PR row) removes with a reason, kept as a struck row; a PR of a repo its role does not take, or one already on another card, is refused at assign.
- Approve on a PR that conflicts with its base records the approval and asks the owner to rebase, re-run CI and merge, instead of refusing.
- Workflow editor: a top-to-bottom flowchart — a card per column with its type's icon, right-angle connectors with the transition name on the line.
- Board header: one control height; the Workflow button shows a miniature of the workflow beside its label.
- Attachments: one row of miniatures, newest first, each linked to its comment.
- Project page: the tmux sessions as status lanes (needs you · working · quiet) with live agent status, and a compact launch bar.
- Agents sidebar: compact rows — the name gets the width, the state is one word, card tags are never cut.
- Today page: compact blocks, today's changes and pending work first.
- Waiting widget: counters per kind (to answer, to review, external).
- Card dialog: the actions that move a card stick to the bottom of the dialog.
- Install and first start: `bin/setup` writes the secrets and lists what is left, `bin/setup check` validates `.env`, every service has a healthcheck; README Quickstart rewritten.
- **Breaking:** the services' timing moved from `.env` to Settings → Runtime: remove `SCAN_INTERVAL_SECONDS`, `WRITER_SYNC_SECONDS`, `GITHUB_INTERVAL_SECONDS`, `GITHUB_CI_INTERVAL_SECONDS`, `NOTIFIER_INTERVAL_SECONDS`, `NOTIFIER_WATCH_SECONDS`, `WATCHDOG_GRACE_SECONDS` (`bin/setup check` refuses them; `bin/runtime-settings import-env < .env` carries their values over).
- **Breaking:** required `config/busyyaks.yml` `launch.scopes` (`{lead_oomd: avoid | none, session_memory_max: <n>K|M|G | null}`, or `null` without a systemd user manager).
- **Breaking:** required `config/busyyaks.yml` `skills` (`{max_bytes, max_start_bytes, project: allow | deny, local_dir}`); see `docs/DEPLOY.md` § Skills.
- **Breaking:** required `config/busyyaks.yml` `github_hook` (`none`, or `{max_body_bytes, wake_seconds}`) and `.env` `GITHUB_WEBHOOK_SECRET` (empty with `none`, at least 32 characters when on).
- **Breaking:** required `config/busyyaks.yml` `updates` (`{remote, branch, tags, channel: tags | branch, check_minutes}`); see `docs/DEPLOY.md` § Updates.
- **Breaking:** required `config/kanban.yml` `progress_watch` (`{stale_minutes}`, or `null` = off).
- **Breaking:** a new compose service `writer`: start it with the others (`docker compose up -d web mcp scanner github notifier writer`).
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

- A handoff or approval right after GitHub's CI was read green no longer gets refused "CI not read yet" because its request had just aged out of the poll window: a read made within the last 3 poll intervals is used as it is.
- Setup wizard: the projects dir step changes the dir — picked in a host dir browser, checked, then applied (the services restart on it).
- Approve is never refused "not read yet" for a card waiting in a gate: its PR checks are kept read; `/github` names a gated card whose reads went stale.
- A link the browser cannot parse is left as written instead of blanking the card.
- Header nav fits phones: it scrolls in its own row, never the whole page sideways.
- Scan errors name an orphaned worktree by its host path and git dir.
- Launcher: a launch whose claude never comes up fails (422), the session is killed and its cards released.
- Launcher start check never refuses before `launch.start_seconds`.
- Scanner: one project per repo — linked worktrees are never projects.
- First approval step read off its own gate's handoff and approve entries.

### Security

- Picomatch 4.0.7 plus the ReDoS fix of an open upstream PR (GHSA-fc5q-39xc-vjpf; no release fixes it), vendored as `4.0.8-busyyaks.0`.
- Puma 8.1.1 (bundle-audit advisories on 8.0.2).
- `auth: none` boots only with `allow_unauthenticated: true` and logs a banner on every boot.
- Session cookie always `HttpOnly`; `Secure` / `SameSite` from `.env`, validated at boot; sign-in redirects to local paths only.
- Host allowlist + Origin check against DNS rebinding.
- MCP on loopback only; refused tokens logged; any `Origin` header refused.
- Daily-report agent limited to two exact git commands in repos under the projects root.
- CI passes GitHub tokens through a pipe, never on a command line.
- Launcher socket private (umask); git `safe.directory` scoped to the mounted repos.
- Credentials stripped from stored remote URLs; Markdown rendered with raw HTML dropped.

[0.1.0]: https://github.com/robertziel/busyyaks/releases/tag/v0.1.0
