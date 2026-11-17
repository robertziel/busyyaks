<div align="center">

<b>Read first: <a href="https://robertz.co/feeds/architecture/how-i-reached-100-prs-a-day/">My agent agency merged 100 PRs in one day. I built them a kanban board so I can micro-manage them like a real boss.</a></b>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="public/static/logo-dark.svg">
  <img src="public/static/logo-light.svg" width="320" alt="busyyaks logo: a yak hauling a cart of task cards, next to the word busyyaks">
</picture>

**Run your own agency, from your own machine, staffed by Claude agents.**

[![tests](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/robertziel/f4d62c00382e99d2952e6185510eeb75/raw/tests.json)](#tests-and-ci)
[![coverage](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/robertziel/f4d62c00382e99d2952e6185510eeb75/raw/coverage.json)](#tests-and-ci)
[![branch coverage](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/robertziel/f4d62c00382e99d2952e6185510eeb75/raw/branches.json)](#tests-and-ci)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Ruby 3.4 · Hanami 2.3](https://img.shields.io/badge/ruby%203.4-hanami%202.3-CC342D.svg)](#stack)
[![React 18](https://img.shields.io/badge/react-18-61DAFB.svg)](#stack)
[![MCP](https://img.shields.io/badge/MCP-streamable%20HTTP-8A2BE2.svg)](#mcp-tools)
[![Agent friendly](https://img.shields.io/badge/agent-friendly-8A2BE2.svg)](#hand-it-to-a-coding-agent)

[Quickstart](#quickstart) · [What you get](#what-you-get) · [How it works](#how-it-works) ·
[The board](#the-board-agents-and-the-operator) · [MCP tools](#mcp-tools) · [Configuration](#configuration) ·
[Docs](#documentation)

</div>

You are brilliant. The people around you just don't get it yet. Good news: you can vibe-code anything now, so stop
waiting for them. Be the boss. Hire a team of agents that never quiet-quit, believe in your vision and always agree
with you. :)

<table>
  <tr>
    <td width="50%" valign="top"><img src="docs/images/board.webp" alt="A project's board: …"></td>
    <td width="50%" valign="top"><img src="docs/images/card.webp" alt="A card opened: …"></td>
  </tr>
</table>

### Merge hundreds of PRs a day!

Always-busy yaks watch your projects locally and follow your orders. You focus on building the roadmap and managing
them.

The panel watches every git repo under a directory and gives you and your agents the same view of them:

- **Today**: commits, active repos and your merged PRs per day, a year-long contribution heatmap, and what is dirty or
  unpushed, so your brain gets its dopamine from the numbers!
- **A kanban board per repo**, the real diamond of this repo. An agent claims a card, asks you a question on it, and
  hands it over with the PR, the CI build and screenshots. It never merges before you approve, so you personally
  ensure the quality of your yaks' work.
- **Launch and supervise agents** in tmux from the browser, see which session is waiting on a permission dialog, and
  answer it from the card.
- **A daily report** written by a local LLM through the same MCP tools, with every number computed by the server.
- **Your GitHub network**: what the people you follow starred, whom they followed, and your github.com feed, summarised.

It runs as five Docker containers plus two host-side processes (the tmux launcher and, optionally, the daily-report
timer). All state is one database: a SQLite file by default, or PostgreSQL ([Database](#database)). It is built for
**one operator on one Linux box**: see [When not to use it](#when-not-to-use-it).

<p align="center">
  <img src="docs/images/today.webp" width="960" alt="The Today page in the dark skin: commit, own-commit, repo and merged-PR tiles with 7-day sparklines, a year-long commit heatmap, a 7-day table and the list of merged PRs; the agents sidebar on the right lists the running agent sessions per project (needs input, PR review, finished); the waiting widget in the corner counts to answer, to review and external. Projects other than busyyaks are shown as acme-N">
</p>

<p align="center"><sub><b>Today</b> (dark skin): the numbers come from the scanner's git reads and from GitHub, never
from a model. The right rail lists the live agent sessions per project. The screenshots are the author's own dashboard
building busyyaks: every other project is renamed <code>acme-N</code> and its text replaced, emails, hosts and people's
pictures removed, and a gate refuses any private word left — captured with
<a href="scripts/readme-images/live"><code>scripts/readme-images/live</code></a>.</sub></p>

## The project

busyyaks is two repos that move together:

- [**busyyaks**](https://github.com/robertziel/busyyaks) (**this repo**) —
  the panel: one dashboard and MCP server over every project on a box, its agents and their boards.
  - [**busyyaks_agents_kanban_module**](https://github.com/robertziel/busyyaks_agents_kanban_module) — the kanban
    engine, vendored here as `agents_kanban` (Ruby module `AgentsKanban`).

The kanban module is built for and with busyyaks, its reference host; it lives in its own repo only so other projects
can ingest it too. See [Two layers](#two-layers-the-panel-and-the-kanban-module).

<p align="center">
  <img src="docs/images/agency.svg" width="736" alt="Two organisations: a human one (leadership, product, design, other engineers, and me as the lead of my agent agency) and the agent agency I lead inside it. I talk directly to one team-lead agent per project; each team lead has agents, junior level, spawned per ticket, each with its own subagents. Three projects are drawn; six more boards run the same way">
</p>

<p align="center"><sub><b>How it is used</b>: one operator, one team-lead agent per project, a worker agent per card —
from <a href="https://robertz.co/feeds/architecture/how-i-reached-100-prs-a-day/">the article</a>.</sub></p>

---

## Requirements

| For | You need |
|---|---|
| the dashboard, scanner, MCP, boards | Linux, Docker Engine 25+ with the compose plugin (2.20+), `git`, a POSIX shell, a directory of git repos — no host Ruby: `bin/setup` is `sh`, everything else runs in the image |
| signing in | nothing on localhost (`auth: { provider: none, allow_unauthenticated: true }`); anything reachable from elsewhere needs an [auth provider](#sign-in) |
| GitHub pages and merged PRs | a GitHub login and a read-only token in `.env` (`gh auth token` with the [`gh` CLI](https://cli.github.com), or a fine-grained token with no repository access) |
| connecting Claude Code (`bin/env` reads `.env`), the launcher (`bin/launcher`, on the host: Launch, claim, dialog answers, new repos), [`yaks`](#the-yaks-command) | Ruby 3.2+ on the host (stdlib only, no gems); the launcher also `git`, `tmux`, the `claude` CLI and a systemd user manager (`systemctl --user`; on a server without a login session: `loginctl enable-linger`) |
| the agents sidebar, typing comments into sessions (optional) | an **agent-session collector** ([below](#agent-sessions)) |
| the daily report (optional) | the runner's CLI (e.g. `hermes`), Ruby 3.2+ (`bin/env` reads `.env`), `jq`, `curl`, `flock`, `timeout` on the host, a systemd user manager, and an OpenAI-compatible LLM gateway |

### Agent sessions

An agent-session collector is a separate host program that walks `/proc` and tmux, writes a JSON snapshot of every
pane running a coding agent, and answers `screen` / `send` requests on a unix socket. The collector this project runs
with is not published yet, so you state which you have in `config/busyyaks.yml` `agents` (required, no default):

| `agents:` | |
|---|---|
| `{ collector: none }` (the shipped example) | works: dashboard, scanner, MCP, boards, Launch, `kanban_claim`, the watchdog, reports, GitHub; a dialog is turned into a question on its card (and answered from there) only when a comment to that session is pending. Off, each saying `agent-session collector off (config/busyyaks.yml agents.collector: none)` where it shows: the agents sidebar, session states and links on cards, Clear idle, the subagent list, typing card comments and answers into a session (the ping is marked failed with that reason), spotting a session stuck on a dialog before anyone comments |
| `{ collector: { snapshot: <file>, read_socket: <socket> } }` | everything; host paths read by `bin/launcher`, which refuses to start while either is missing |

---

## Quickstart

Host Ruby is not needed for these steps ([Requirements](#requirements)). Each one stops with the reason and the fix
when something is missing; run the next only once the previous succeeded.

<!-- quickstart:start (scripts/ci/quickstart-test replays this block in a container without Ruby) -->
```bash
git clone https://github.com/robertziel/busyyaks && cd busyyaks

# copies .env.example → .env, config/busyyaks.example.yml → config/busyyaks.yml and config/kanban.example.yml →
# config/kanban.yml (an existing file is kept), writes the secrets that are empty (SESSION_SECRET, MCP_TOKEN,
# MCP_REPORT_TOKEN) and HOST_UID / HOST_GID, then lists the values left to fill
bin/setup

# fill what bin/setup listed — PROJECTS_ROOT, LAUNCHER_RUN_DIR, GITHUB_LOGIN, GITHUB_TOKEN, TEAM_TERMINAL_URL,
# SSH_ATTACH_TEMPLATE — each explained above its line; groups 4-6 of .env work as shipped (SQLite, ports 8080 / 8081)
$EDITOR .env

# every value compose requires set, HOST_UID = you, PROJECTS_ROOT a real directory; creates ./data and
# LAUNCHER_RUN_DIR (0700) as you, then compose's own check of .env — each problem named with its fix
bin/setup check

# builds the image (a few minutes the first time) and returns once every service runs and web answers /up;
# "container … is unhealthy" / "dependency failed to start": docker compose logs web says why
docker compose up -d --build --wait web mcp scanner github notifier
```
<!-- quickstart:end -->

config/busyyaks.yml as copied: every repo under `PROJECTS_ROOT`, no sign-in (`auth: none`, localhost only), no
agent-session collector; config/kanban.yml: the board's caps, theme and gates (the launchers and agent types are
edited on Settings → Agents & launchers, in the database; a fresh one starts with config/agents.template.yml: plain
`claude`).

Open `http://127.0.0.1:8080` (`WEB_HOST_PORT`) — with `provider: none` there is no sign-in; the first page is the
hello screen (`/hello`), which checks the database, the scanner, the launcher and GitHub and says what each needs.
The scanner reads every repo under `PROJECTS_ROOT` (mounted read-only) within `SCAN_INTERVAL_SECONDS`.

Connect Claude Code to the MCP server:

```bash
vars=$(bin/env MCP_HOST MCP_HOST_PORT MCP_TOKEN) && eval "$vars"   # bin/env: the one .env reader (host Ruby 3.2+)
claude mcp add --transport http --scope user busyyaks "http://$MCP_HOST:$MCP_HOST_PORT/mcp" \
  --header "Authorization: Bearer $MCP_TOKEN"
```

Install the host launcher (systemd `--user`; host Ruby 3.2+, `tmux`, `claude`). Fill `.env` group 3 (`LAUNCHER_STATE_DIR`,
`CLAUDE_SESSIONS_DIR`) first. Agents' board tools check the agent's tmux session through it, and the launch bar starts
sessions with it:

```bash
deploy/install-launcher.sh
```

An agent then starts with `whats_new` and works its project's board with the `kanban_*` tools. Without the launcher,
the dashboard, the scanner and MCP's read tools work, but agents cannot register, claim, create or ask on cards. The
agents sidebar and typing comments into sessions also need an [agent-session collector](#agent-sessions).

Optional: the [daily report](#the-daily-report) timer, `deploy/install-daily-timer.sh`.

### The `yaks` command

`bin/yaks` runs the checkout it lives in, from any directory. It needs host Ruby 3.2 or newer (stdlib only: no
gems, no `bundle install`). The stack's commands (`server`, `panel`, `env`, `doctor`) need Linux; `yaks desktop`
also runs on the BSDs and macOS ([Desktop app](#desktop-app)).

**Install** — one symlink from a directory on your PATH (the example uses `~/.local/bin`; any PATH directory works):

```sh
ruby -v                                    # 3.2 or newer
mkdir -p ~/.local/bin
ln -s "$PWD/bin/yaks" ~/.local/bin/yaks    # run from the checkout; the link must point at the real bin/yaks
command -v yaks                            # ~/.local/bin/yaks; nothing → add ~/.local/bin to PATH in your shell profile
yaks doctor                                # every row ok (miss = optional)
yaks server status                         # every row ok once the stack is up
```

| | |
|---|---|
| update | nothing to do: the link follows the checkout, so a `git pull` / local deploy updates `yaks` too. Moved or renamed the checkout → the link breaks: `ln -sf <new checkout>/bin/yaks ~/.local/bin/yaks` |
| uninstall | `rm ~/.local/bin/yaks` |
| several checkouts | one link per checkout, under different names (`ln -s <checkout>/bin/yaks ~/.local/bin/yaks-test`) |
| exit codes | 0 ok · 1 a check failed or a refusal (the reason on stderr) · 2 a usage error (usage printed) |
| `no .env at <checkout>/.env` | the link points at a checkout that is not set up: finish the [Quickstart](#quickstart) there, or link the right checkout |
| `Ruby X is older than 3.2` · `busyyaks runs on Linux only` | refused before anything runs (the stack's commands; `yaks desktop` and `help` run on Linux, the BSDs and macOS) |
| `yaks panel`: `no graphical session here` | run it from a desktop session; over ssh / tmux use `yaks panel --print` |

Commands:

| Command | Does |
|---|---|
| `yaks server status` | each service running, `/up`, MCP `tools/list`, the launcher unit and its socket; exit 1 if any is down |
| `yaks server logs [SERVICE] [-f]` | `docker compose logs` of the stack or one service |
| `yaks panel [--print]` | opens the dashboard with `xdg-open` from a desktop session (`https://PUBLIC_HOST`, or `http://127.0.0.1:WEB_HOST_PORT`); over ssh / tmux it is refused — `--print` prints the URL |
| `yaks desktop install --browser NAME` · `yaks desktop open` · `yaks desktop uninstall` | the [desktop app](#desktop-app) (Linux, the BSDs: a `.desktop` entry; macOS: `~/Applications/busyyaks.app`): the server chooser in its own window, then each server in a window of its own (`NAME --app=<URL>`); uninstall removes only this checkout's entry |
| `yaks env KEY...` | `export KEY='value'` lines from `.env` (as `bin/env`) |
| `yaks env --ports` | this server's host name and its loopback web / MCP ports as JSON — what [`yaks remote connect`](#remote) asks over ssh; no secret |
| `yaks remote add\|list\|remove\|connect\|attach` · `yaks remote --stdio` | a busyyaks server on another machine, over your own ssh: [Remote](#remote) |
| `yaks doctor` | every host tool the stack needs, per feature, and the first start's checks; exit 1 if one fails |

**How it works from the terminal.** `yaks` finds its checkout from the symlink's real path, reads that checkout's
`.env`, and runs everything there — so it works from any directory. `server status`, `server logs` and `doctor` only
read: they run `docker compose ps` / `logs` in the checkout, ask `GET /up` on `127.0.0.1:WEB_HOST_PORT` and MCP `tools/list` on
`MCP_HOST:MCP_HOST_PORT` (bearer `MCP_TOKEN`), `systemctl --user is-active busyyaks-launcher.service` and look for
`LAUNCHER_RUN_DIR/launcher.sock`; they start, stop or write nothing (`logs -f` follows until Ctrl-C). `panel` starts
`xdg-open` with the dashboard URL. A session:

```console
$ yaks help
usage: yaks <command>

  yaks server status                   every service, /up, MCP tools/list, the launcher unit and its socket; exit 1 if any is down
  yaks server logs [SERVICE] [-f]      docker compose logs of the stack (or of one service); -f follows
  yaks panel [--print]                 open the dashboard in the browser (xdg-open); --print prints its URL instead
  yaks desktop install --browser NAME  busyyaks in the app menu: the server chooser in its own window (Linux, BSD, macOS)
  yaks desktop open --browser NAME     the chooser now: Local (the default) and the saved servers, each in its own window
  yaks desktop uninstall               remove that entry
  yaks env KEY...                      `export KEY='value'` lines from .env, for eval (bin/env)
  yaks env --ports                     this server's host name and ports as JSON (what `yaks remote connect` asks over ssh)
  yaks remote add|remove TARGET        save / forget a busyyaks server reached over ssh (a Host alias or user@host)
  yaks remote list                     the saved servers (connects to nothing)
  yaks remote connect TARGET [--mcp]   forward its dashboard (and MCP) to this machine over ssh, until ssh ends
  yaks remote attach TARGET SESSION    an agent's terminal on that server, here, over ssh
  yaks remote --stdio                  server side of attach: ssh's stdin/stdout ↔ the launcher socket
  yaks doctor                          every host tool the stack needs, per feature, and the first start's checks; exit 1 if one fails
  yaks help                            this list

$ yaks server status
ok    web                        running
ok    mcp                        running
ok    scanner                    running
ok    github                     running
ok    notifier                   running
ok    web /up                    HTTP 200
ok    mcp tools/list             46 tools
ok    busyyaks-launcher.service  active
ok    launcher socket            /home/you/.local/state/busyyaks/run/launcher.sock

$ yaks doctor
ok    docker               /usr/bin/docker                        the stack (yaks server)
ok    git                  /usr/bin/git                           the launcher
ok    tmux                 /usr/bin/tmux                          the launcher
ok    claude               /home/you/.local/bin/claude            the launcher
ok    systemctl            /usr/bin/systemctl                     the launcher, the daily report (systemd --user)
ok    xdg-open             /usr/bin/xdg-open                      yaks panel
ok    docker compose       2.32.4                                 the stack (yaks server)
ok    systemd --user       running                                the launcher, the daily report
miss  graphical session    none (ssh / tmux): yaks panel --print  yaks panel
ok    config/busyyaks.yml  daily_report_runners set               every service
ok    jq                   /usr/bin/jq                            the daily report
ok    curl                 /usr/bin/curl                          the daily report
ok    flock                /usr/bin/flock                         the daily report
ok    timeout              /usr/bin/timeout                       the daily report
ok    ruby                 3.2.3 (>= 3.2)                         yaks, the launcher, bin/env
ok    .env                 the 38 keys compose requires set       the first start (bin/setup check)
ok    config/kanban.yml    present                                the first start (bin/setup check)
ok    HOST_UID:HOST_GID    1000:1000 (you)                        the first start (bin/setup check)
ok    PROJECTS_ROOT        /home/you/projects                     the first start (bin/setup check)
ok    ./data               /home/you/busyyaks/data                the first start (bin/setup check)
ok    LAUNCHER_RUN_DIR     /home/you/.local/state/busyyaks/run    the first start (bin/setup check)

$ yaks server logs scanner -f        # Ctrl-C stops following
scanner-1  | scan ok repos=121 seconds=21.3

$ yaks panel --print
https://busyyaks.example.com

$ eval "$(yaks env WEB_HOST_PORT)" && echo "$WEB_HOST_PORT"
3000
```

`ok` = found / up · `miss` = optional and absent (only `yaks panel`'s needs; never fails doctor) · `FAIL` = missing,
exit 1. The jq · curl · flock · timeout rows appear only when `config/busyyaks.yml` has `daily_report_runners`. The
first-start rows read what [`bin/setup check`](#quickstart) makes (doctor writes nothing): no `.env` → one FAIL row.

---

## What you get

| Page | Shows |
|---|---|
| **Today** `/` | per-day commits · yours · active repos · your merged PRs over `window_days`; the year heatmap; tracked / uncommitted / unpushed counts; the last scan |
| **Projects** `/projects` | every repo: branch, last commit, window commits, dirty, unpushed, cards per column; launch agents; create or clone a repo |
| **Project** `/projects/<slug>` | **Board** (below) and **Overview**: the branch, commits and notes. A [Backlog.md](https://github.com/MrLesk/Backlog.md) `backlog/` folder shows its tasks on the board, read-only |
| **Reports** `/reports` | the daily reports and anything an agent posted with `post_report`; `/reports/components` is the block library |
| **GitHub** `/github` | the people you follow: their stars and new follows over 24h · 7d · 30d; your github.com feed summarised |
| **Agents** sidebar | every tmux session running a coding agent, by project, worst first: blocked (a dialog or a question) · review · working · finished · idle; links to its terminal and its Claude Code Remote Control session; **Open terminal** shows its live screen in the page, read-only until **Take control** ([Terminals](docs/DEPLOY.md#terminals-an-agents-live-screen)) |

Two skins (light by default, dark, or follow the system), Trello-style keyboard shortcuts on the board (`?`), and a search
over projects, cards, commits and reports (`⌘K`).

**Desktop app**: the dashboard runs as an app in a window of its own — see [Desktop app](#desktop-app).

<p align="center">
  <img src="docs/images/board.webp" width="960" alt="busyyaks' own board: the session lanes on top (Needs you: a PR to review; Quiet: finished workers) and the launch bar with Launch, Worker, Sub team and Plain on their launcher; the column counts (waiting for you, waiting for CI, Local and Public review loops, Done); below them the columns Backlog, To do, In progress and Local: Agent review with cards, their picture covers, review rounds and the session that owns each">
</p>

<p align="center"><sub><b>Board</b>: the session lanes say who needs you (answer a dialog or a question in place),
who works and on what; the launch bar starts the lead first, then workers, a sub team or a plain session in tmux; each
card shows the session that owns it and whether anyone is listening.</sub></p>

<table>
  <tr>
    <td width="72%"><img src="docs/images/card.webp" alt="A busyyaks card (the waiting widget's kind counters) opened in Awaiting merge: its hand-off box with the public PR, the CI build, how to check it and its screenshots (drawn as blank plates), the Links rail with the local and public PRs and their state, the CI build, branches and commits, and the owner session panel with its Claude, iTerm and Terminal links and the last ping"></td>
    <td width="28%"><img src="docs/images/today-mobile.webp" alt="The Today page on a phone in the dark skin: the stat tiles two per row, the commit heatmap and the waiting widget"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>Card</b>: the hand-off (PR, CI, how to check it), its PRs and their state, and the session comments are typed into.</sub></td>
    <td align="center"><sub><b>Phone</b>.</sub></td>
  </tr>
</table>

---

## Desktop app

The dashboard is the same web app in a window of its own: no tabs, no address bar, an entry in the applications menu.
Two ways, both on the machine you work at:

| | How | Gives |
|---|---|---|
| **`yaks`** (Linux · FreeBSD · OpenBSD · NetBSD · DragonFly · macOS) | `yaks desktop install --browser google-chrome` | an app **busyyaks** that opens the [server chooser](#server-chooser), then each dashboard with the browser's `--app=<URL>`. Linux and the BSDs: a menu entry `~/.local/share/applications/busyyaks.desktop` (the browser found on `PATH`). macOS: `~/Applications/busyyaks.app` (Launchpad, Spotlight), starting the browser app from `/Applications` or `~/Applications`. The window belongs to the browser, so the Dock / taskbar shows it under the browser's icon. Remove it with `yaks desktop uninstall` |
| **From the browser** (Linux · macOS · Windows) | open the dashboard in Chrome or Edge → the install icon at the right of the address bar (or ⋮ menu → *Cast, save, and share* → *Install busyyaks…*) | the installed app: its own window and its own Dock / taskbar icon, with a badge counting the cards waiting for you (a dot when the count could not be read) |

`--browser` is required, a Chromium-family browser (only those open a window of its own): `google-chrome`,
`chromium`, `microsoft-edge`, `brave-browser`, `vivaldi`; on Linux / BSD also their package names
`google-chrome-stable`, `chromium-browser`, `microsoft-edge-stable`. Install and uninstall touch only the entry this
checkout wrote.

The URL is the dashboard's, from the checkout's `.env`: `https://PUBLIC_HOST`, or `http://127.0.0.1:WEB_HOST_PORT`
while `PUBLIC_HOST` is empty (`yaks panel --print` prints it). An installed app needs a secure origin, which both are.

**On a machine that only opens the dashboard** (e.g. a Mac reaching the server over `PUBLIC_HOST`) — no stack, no
Docker, only a clone and Ruby 3.2 or newer (macOS ships an older one: `brew install ruby`, then put Homebrew's ruby
first on PATH):

```sh
git clone https://github.com/robertziel/busyyaks && cd busyyaks
ruby -v                                              # 3.2 or newer
echo 'PUBLIC_HOST=busyyaks.example.com' > .env       # the server's PUBLIC_HOST: the only key it reads
ruby bin/yaks desktop install --browser google-chrome
open ~/Applications/busyyaks.app                     # macOS; Linux / BSD: the applications menu, busyyaks
```

The rest of `yaks` (the stack's commands) runs on Linux only. A new app can take a moment to show in Launchpad or
Spotlight; `open ~/Applications/busyyaks.app` starts it at once. Firefox on the desktop does not install web apps.
Changed `public/static/icon.svg`? Re-render the app icons with `scripts/icons/render-png` (Docker).

## Remote

A busyyaks server on another machine, from the one you work at, over **your own ssh**: keys, ssh-agent,
`~/.ssh/config` aliases and bastions are ssh's. busyyaks opens no TCP listener and has no TLS of its own for this; the
server keeps its sessions, and closing the window or the tunnel ends nothing there.

```sh
yaks remote add myserver                  # a ~/.ssh/config Host alias or user@host; saved, nothing connected
yaks remote list                         # the saved servers; connects to nothing
yaks remote connect myserver              # forwards the dashboard until Ctrl-C; prints its URL
yaks remote connect myserver --mcp        # + the MCP port, and the `claude mcp add` line for this machine
yaks remote attach myserver <tmux session>                  # an agent's terminal here (read-only first)
yaks remote remove myserver
```

| | |
|---|---|
| Saved servers | `$XDG_CONFIG_HOME/busyyaks/remotes.yml` (else `~/.config/…`), mode 0600, per user — never in a checkout. Only `yaks remote add` writes one |
| `connect` | asks the server `ssh TARGET yaks env --ports`, then `ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:P:127.0.0.1:P TARGET`. **P is the server's own `WEB_HOST_PORT`**: the server answers only `Host: 127.0.0.1:WEB_HOST_PORT` (DNS-rebinding guard), so the local end is that same port and the server needs no change. That port already taken here (a local busyyaks on it, another connect) → refused, nothing forwarded; a forward ssh cannot open → ssh's own reason, exit non-zero |
| `--mcp` | also forwards `MCP_HOST:MCP_HOST_PORT` and prints `claude mcp add … --header "Authorization: Bearer $MCP_TOKEN"`. The bearer stays on the server: copy it from there yourself — yaks never reads, prints or sends it |
| Page state | the header shows the server's host name, accented, on a forwarded window, and the connection: `reconnecting…` after one failed `/up` (every 3 s), `down` after two — the page dims under "Connection down — this page is not live" |
| `attach` | `ssh TARGET yaks remote --stdio` carries the agent terminal stream: the screen first, then live; read-only until `Ctrl-]` `t` (the server confirms control), `Ctrl-]` `q` detaches |
| `--stdio` (server side) | what ssh runs: one request line, only the `attach` op, bridged to the launcher socket — refused unless that socket is the ssh user's own |
| Needs | the server: `yaks` on the PATH ssh commands get (non-interactive: `~/.profile` may not run — a symlink in `/usr/local/bin` does); this machine: Ruby 3.2+, a clone, `ssh` |

Refusals: an unknown name (`not a saved server`), a target that is not one (`-o…`, spaces), a server without
busyyaks (`has no busyyaks: yaks is not on its PATH`), the forward port taken, an op other than `attach` over `--stdio`.

### Server chooser

The desktop app (`yaks desktop install`) opens a chooser first: **Local** (this checkout's dashboard, the default:
selected, Enter opens it) and every saved server, each with its state. The dashboard itself is unchanged.

| | |
|---|---|
| Open | Local → a window on this checkout's dashboard. A server → its forward (as `connect`, ssh with `BatchMode=yes`: a key from ssh-agent or without a passphrase), held by the chooser; once its `/up` answers 200 through it, a window on it (with its host name in the header). Open again → another window, no second forward |
| States | Local: running · not answering · no local busyyaks (why: no `.env`, …). A server: not connected · connecting… · connected (host, port) · failed with ssh's or the server's own words (port taken here, no busyyaks there, `/up` not 200 within 15 s) |
| Add · Remove · Disconnect | the saved servers file, the same as `yaks remote add` / `remove`; Remove asks once more and disconnects first |
| Several servers | each its own window at once, while their ports differ (each forward uses its server's own port) |
| Lifetime | one chooser per user: opening the app again opens another chooser window on it. **Closing the last chooser window disconnects every server** (10 s later); the server windows show `down` |
| Guards | its own page on `127.0.0.1:<free port>`: only `Host: 127.0.0.1:<port>`; a one-time launch code (60 s) → an HttpOnly, SameSite=Strict cookie; every change also needs its own `Origin`. State in `$XDG_STATE_HOME/busyyaks` (else `~/.local/state/…`), 0700 |

---

## How it works

<p align="center">
  <img src="docs/images/architecture.svg" width="720" alt="How busyyaks works: the browser reaches the web container with a session cookie and the Claude Code sessions reach the mcp container with a bearer token; web, scanner, github, mcp and notifier run in docker compose over one database (SQLite or PostgreSQL); a unix socket connects them to bin/launcher on the host, which starts the tmux sessions and captures their dialogs">
</p>

| Process | What it does |
|---|---|
| `web` | Serves the SPA shell for every signed-in GET and the `/api/*` JSON API. Markdown (reports, notes, cards) is rendered on the server with raw HTML dropped. |
| `mcp` | The MCP endpoint, local only. Refuses any request that carries an `Origin` header. |
| `scanner` | Every `SCAN_INTERVAL_SECONDS`: log, status and upstream of each repo under the configured roots. A repo is a dir with `.git`; group dirs are searched `search_depth` levels down. Every read is one short-lived child (`bin/git-read`, libgit2: it runs no program a repo's config names) with hard limits (`GIT_READ_*`); a repo it cannot read is an error on that repo, never the git CLI instead. |
| `github` | Every `GITHUB_INTERVAL_SECONDS`: the network, the feed, your merged PRs and PR states for the board. The only container that holds `GITHUB_TOKEN`; conditional requests (ETag) everywhere. |
| `notifier` | Delivers the operator's comments, moves and answers to the owning session; turns a session stuck on a dialog into a question on its card; releases cards whose session is gone. |
| `bin/launcher` | Runs on the host, because the containers cannot reach the host's tmux. Starts sessions, lists them, captures and answers dialogs, clones repos. |
| `bin/daily-report` | Runs on the host from a systemd timer. See [the daily report](#the-daily-report). |

### Stack

Hanami 2.3 · Puma · Sequel on SQLite or PostgreSQL · `ruby:3.4-slim` · minitest · React 18 + TypeScript + Vite (built in the image's
node stage) · vitest.

### Two layers: the panel and the kanban module

| Layer | Repo | Role |
|---|---|---|
| **Panel** | this repo | One dashboard and MCP server over **every** project on the box: scanner, Today, agents sidebar, launches, daily report, GitHub network, one board per project. |
| **Kanban module** | [busyyaks_agents_kanban_module](https://github.com/robertziel/busyyaks_agents_kanban_module) | The board itself: store, workflow, gates, session registry, notifier, `kanban_*` MCP tools, React board. busyyaks is its reference host. |

busyyaks keeps no kanban code of its own: it vendors a pinned module sha (`vendor/agents_kanban`,
`frontend/src/vendor/agents_kanban`, refreshed only by `scripts/vendor-kanban-engine.sh`) and supplies the host side:
its config (`config/kanban.yml` + the agent settings in the database), the launcher and the repo links. The two move together: a board change is a module
PR plus a busyyaks PR that re-vendors it, merged as one change. The module has its own repo so that other projects
can vendor it too.

---

## The board: agents and the operator

Every repo gets a board. The default columns are **Backlog → To do → In progress → QA → Human Check → Ready to merge →
Merged**. Columns, their types and the named transitions between them are stored in the database;
the operator edits them in a graph editor (the board's **Workflow** button).

| Who | Can |
|---|---|
| Agent (MCP) | create and claim cards, comment, attach files, move cards between the working columns; after approval, merge the PR and move the card from Ready to merge to Merged |
| Agent asks the operator | only through `kanban_ask(id, question, author, options?)`: the card keeps its column and is flagged as waiting for you; the options become buttons on the card |
| Agent → Human Check | only through `kanban_handoff` with the QA steps, the PR URL and the CI URL; a UI change is refused without screenshots |
| Operator (web) | everything, and is the only one who moves a card out of Human Check into Ready to merge. The agent merges only after that. |

Sessions are tied to cards. A session started from the launch bar is registered before tmux starts it. A **lead**
adopts the cards that wait for the operator. A **worker** is spawned for an ownerless card in a working column. A
**sub team** runs alongside the lead. Comments and answers are typed into the owner's tmux session; when nobody is
listening the card says so. Caps on concurrent sessions are config (`config/kanban.yml`, and per agent type on Settings → Agents & launchers): by default none, except one
lead per board.

The full contract is [`vendor/agents_kanban/SPEC.md`](vendor/agents_kanban/SPEC.md); the HTTP API is
[`docs/API-kanban.md`](docs/API-kanban.md).

---

## Workflows

A board's workflow is data, stored in the database: its **columns**, each of one **type**, in board order, and the
**named transitions** between them. Every board has one; a new project gets a copy of the template.

| Column type | Rules |
|---|---|
| `parked` | nobody listens; agents may create cards here |
| `queued` | listened; one per board; the lead's ownerless work, each card started with `kanban_spawn`; a card released from the first working column returns here |
| `working` | listened; several per board; the first one is watched (owner gone → card back to `queued`); a card released in any other working column stays put |
| `review` | listened; review rounds counted per loop column (`review_loop.max_rounds`) |
| `gate` | waits for the operator; agents enter only with `kanban_handoff`; its one forward operator exit is an approval step |
| `done` | exactly one per board; agents enter only from a gate, once approved (a board without a gate: anyone may finish a card), and never leave |
| `cancelled` | at most one; only the operator moves a card in or out |

| Transition `{name, from, to, by}` | |
|---|---|
| `by: agent` · `any` | agents move only along these, by name (`kanban_move(transition: …)`); no edge → refused, the edges listed |
| `by: operator` | the operator's (web); busyyaks' boards add a catch-all `Move` (`* → *`, board config), so the operator drags a card to any column |
| flags | `needs_operator` (`kanban_ask`) and `blocked_external` (`kanban_block`) keep the card's column and refuse agent moves |

| Gates and approvals | |
|---|---|
| enter | only `kanban_handoff` (QA steps, PR URL, CI URL; screenshots for a UI change) |
| green CI first | a handoff into an approval gate and every explicit approval (the **Approve** button, the step's named transition) are refused until the step's PR checks are read and green (`approval.requires_green_ci`); the operator's drag is never refused by it |
| approve | the gate's **Approve** button (card dialog) records who approved and pings the owner, who then takes the next named transition |

| Edit · read | |
|---|---|
| operator | the board's **Workflow** button → graph editor: add / rename / retype / delete columns (refused while cards sit in one), connect transitions, reorder, Save · Discard · Reset to template; the layout is automatic (top to bottom) |
| agents | `kanban_workflow` (read-only: no tool writes a workflow); each card's JSON lists its `transitions` |
| API | `GET` / `POST` / `DELETE /api/projects/<slug>/workflow` ([`docs/API-kanban.md`](docs/API-kanban.md)) |

<p align="center">
  <img src="docs/images/workflow.webp" width="720" alt="The Workflow graph editor on busyyaks' own 15-column board, top to bottom: Backlog (parked) → To do (queued) → In progress (working) → Agent review ↔ Author response loops, Local and Public Human review, Deploy check and Awaiting merge gates marked waits for you, Done and Cancelled; each arrow is a named transition such as Start work, Hand over, Approve, Merge, Rework; the column list with each column's type is on the right">
</p>

<p align="center"><sub><b>Workflow</b>: busyyaks' own board, the engine's local-repo shape (15 columns, two review
loops, four gates), in the graph editor; dashed arrows go back up the board order.</sub></p>

---

## Skills

The workflow busyyaks's agents follow (asking on a card, handing off on green CI, review loops, never merging before
your approval) is a set of skills in `skills/`, handed to each session busyyaks starts — per launch only (Claude Code
`--plugin-dir`, hermes through one env-gated `external_dirs` line); your own `claude` / `hermes` sessions are not
touched. A project adds its own in `.busyyaks/skills.yml` + `.busyyaks/skills/<name>/SKILL.md`, loaded for the agent
types it names when the repo is trusted. Format and rules: `docs/DEPLOY.md` § Skills.

---

## MCP tools

| Tool | Does |
|---|---|
| `whats_new(date?)` | that day's reports, commits per repo since midnight, dirty and unpushed repos, the last scan |
| `list_projects(own?, active_days?)` · `project(slug, limit?)` | repos with branch, last commit, window counts; one repo with commits and notes |
| `daily_facts(hours, series)` | the daily report's numbers, computed: commits vs the previous window, active repos, pending work, cards waiting for the operator |
| `github_network(hours)` | stars, follows and the feed in a window, plus a ready-made report block |
| `report_components()` · `check_report(body)` · `post_report(...)` | the report block library; a dry-run check of a draft; publish |
| `list_reports` · `get_report` · `add_note` · `list_notes` · `scan_now` | reports, notes, an immediate rescan |
| `daily_report_config()` | how the daily report runs here (Settings → Daily report's current revision, validated; `configured: false` + why when none runs) |
| `kanban_*` (29 tools) | the board: `kanban_board`, `kanban_card`, `kanban_create`, `kanban_claim`, `kanban_comment`, `kanban_ask`, `kanban_handoff`, `kanban_move`, labels, checklists, due dates, attachments, `kanban_workflow` |

The server's `instructions` tell an agent how to use the board: claim before working, ask on the card instead of in
chat, hand off with `kanban_handoff`, and never poll.

---

## The daily report

Optional, configured on **Settings → Daily report** (stored in the database; the runners it may pick are `config/busyyaks.yml` `daily_report_runners`). Not configured → one visible `NOT CONFIGURED` report a day. `bin/daily-report` runs on the host from a systemd
user timer (`deploy/install-daily-timer.sh`): it probes your OpenAI-compatible gateway and starts a runner (today:
[Hermes](https://github.com/NousResearch/hermes-agent)) whose only tools are the busyyaks MCP server and read-only
`git log` / `git status`. The model writes the prose; every figure comes from `daily_facts`, and `check_report`
rejects a draft that names repos, people or events the server does not know. A gateway that is down means no report
(or one `NOT RUN` report after the cutoff), never a stand-in model.
Details: [`docs/DAILY-REPORT.md`](docs/DAILY-REPORT.md).

---

## Configuration

A deployment is configuration, never code. One place per value; an unknown or missing key is an error.

| File | Holds |
|---|---|
| `.env` (from [`.env.example`](.env.example)) | wiring and secrets: ports, `PROJECTS_ROOT`, the host user the containers run as (`HOST_UID`/`HOST_GID`), timezone, session secret, `MCP_TOKEN`, GitHub login and token, intervals, attachment limits. Compose uses `${VAR:?}`, so a missing value stops it. |
| `config/busyyaks.yml` (from [`config/busyyaks.example.yml`](config/busyyaks.example.yml)) | repo roots and search depth, your remotes and author emails, the history window, `reap_protect` (sessions "Clear idle" never stops), `auth` ([Sign-in](#sign-in)), `agents` ([Agent sessions](#agent-sessions)), optional `engines:` and `daily_report_runners` (the runners Settings → Daily report may pick; a bad one stops the scanner and github services at boot and fails the `daily_report_config` tool). |
| `config/engines.yml` (committed) | the coding-agent engine names a collector reports → sidebar label + behaviour family (`claude` · `hermes`); `engines:` in `config/busyyaks.yml` adds or relabels. |
| `config/kanban.yml` (from [`config/kanban.example.yml`](config/kanban.example.yml); the file `KANBAN_CONFIG` names) | the kanban module's host settings: concurrency caps, theme, the handoff / approval gates, the review loop. Not the launchers and agent types: they are rows in the database, edited on **Settings → Agents & launchers** (the header's cog). |
| Settings → Agents & launchers (`/settings`; repo default [`config/agents.template.yml`](config/agents.template.yml)) | the launchers (the commands that start an agent session: kind `claude_code` or `hermes`, command, args, via shell) and the agent types (their launchers, model per launcher, prompt, caps). Every save is a new revision (history kept). A launcher is one of the invocations on `config/busyyaks.yml` `launch.commands`, **the host allowlist** (each a whole `{kind, command, args, via_shell}`): the page offers only those, and anything else is refused when saved and again by `bin/launcher` when it starts — no dashboard user can add an argument the host did not list. The fresh database runs plain `claude` in Claude Code's default permission mode (a permission prompt becomes a question on the card). |

### Database

`.env` `DATABASE_ADAPTER` picks it; there is no default, the shipped `.env.example` says `sqlite`.

| `DATABASE_ADAPTER` | Keys (`.env`) | What runs |
|---|---|---|
| `sqlite` | `SQLITE_BUSY_TIMEOUT_MS` | `data/busyyaks.sqlite3`, nothing else. WAL, every transaction `BEGIN IMMEDIATE` ([`docs/DEPLOY.md`](docs/DEPLOY.md#the-database)) |
| `postgresql` | `POSTGRES_HOST` · `POSTGRES_PORT` · `POSTGRES_DB` · `POSTGRES_USER` · `POSTGRES_PASSWORD` (the password only in `.env`) · `POSTGRES_LOCK_TIMEOUT_MS` | your server, or the compose `postgres` service: `COMPOSE_PROFILES=postgres`, `POSTGRES_HOST=/data/postgres-run`, `POSTGRES_PORT=5432` (runs as `HOST_UID`, cluster in `data/postgres`, a Unix socket, no network) |

Every key stays in `.env`; the chosen adapter's must be filled (a missing, empty or unknown value stops every service
at boot). Switching starts on an empty database, unless you copy it: `bin/db-copy-sqlite-to-postgres` moves a SQLite
file into an empty PostgreSQL database and verifies every table ([runbook](docs/DEPLOY.md#switching-sqlite--postgresql-one-time-the-data-moves)).
CI runs the full test suite on both (`ruby` = SQLite, the public default; `ruby-pg` = PostgreSQL).

Some `.env` values point at tools outside busyyaks; every one is required:

| Key | What to put there |
|---|---|
| `TEAM_TERMINAL_URL` | a web terminal that opens a tmux session (`{session}`, `{socket}`); behind the board's **Terminal** links. Required, no example value: without such a tool, the dashboard's own URL (each session's live screen is its **Open terminal** button) |
| `SSH_ATTACH_TEMPLATE` | the command the **iTerm** button copies, e.g. `ssh -t your-host tmux attach -t {session}` |
| `CLAUDE_SESSIONS_DIR` · `CLAUDE_SESSION_URL` | where Claude Code keeps its live session records, and the Remote Control URL (`{id}`) behind the **Claude** links |

Comments and answers are typed only into panes whose engine is in the `claude` family; for any other pane the
launcher answers `cannot type into <engine> (family hermes)` or `(not configured)` and nothing is typed.

---

## Sign-in

Sign-in is a pluggable **auth provider**, chosen in `config/busyyaks.yml` `auth`. There is no default: a missing
`auth` key, an unknown provider or settings the provider refuses stop the boot.

| `auth:` | What it does |
|---|---|
| `{ provider: none, allow_unauthenticated: true }` (the shipped example) | no sign-in: every request is the operator (shown as `operator`); no sign-out. The opt-in key is required (`provider: none` alone stops the boot) and every boot logs `*** AUTH DISABLED … ***`. Keep the dashboard on localhost or behind your own SSH tunnel; never behind a public proxy ([`docs/DEPLOY.md`](docs/DEPLOY.md)) |
| `{ provider: <dir>, <settings…> }` | a custom provider: `<dir>` (e.g. `auth/myidp`) holds `provider.rb`, a `Busyyaks::Auth::Provider` subclass; the block's other keys are its settings. How to write one: [`docs/AUTH.md`](docs/AUTH.md) |


The MCP endpoint does not use sign-in: it takes a bearer token (`MCP_TOKEN`), listens on `127.0.0.1` only, and should
never be exposed. The daily report has its own bearer, `MCP_REPORT_TOKEN`, which reaches only the report's tools (reads,
`check_report`, `post_report`): its model reads untrusted text, so it never gets a tool that writes a card.

---

## Running in production

- All ports bind to `127.0.0.1`. **Localhost only is the default** and needs nothing more. To reach the dashboard
  from elsewhere, use same-host nginx + TLS or an frp tunnel to a public proxy host: [`docs/DEPLOY.md`](docs/DEPLOY.md).
  `deploy/` has templates only; `bin/render-deploy` fills them from `.env` into `deploy/rendered/` (gitignored).
- The two host processes are systemd `--user` units: `deploy/install-launcher.sh` and `deploy/install-daily-timer.sh`.
  The launcher unit uses `KillMode=process`, so restarting it leaves your tmux sessions running.
- Back up `data/` (card attachments, and the SQLite file: `VACUUM INTO` while it runs, [`docs/DEPLOY.md`](docs/DEPLOY.md#the-database)) — on PostgreSQL, the server too (`pg_dump`). Migrations run when `web` starts.
- The containers run as `HOST_UID:HOST_GID`, the launcher's user. Every service (`bin/entrypoint`) refuses to start
  while anything under `data/` belongs to another user or cannot be read (a `data/` Docker created as root, files from
  a version whose containers ran as root, a directory without read permission) and prints the one-time fix:
  `docker compose run --rm --no-deps --user root web sh -c 'chown -R <uid>:<gid> /data && chmod -R u+rwX /data'`.
- Repos are mounted read-only. busyyaks never changes an existing repo (agents do, in their own tmux sessions); the
  launcher can create or clone a new one when you ask it to from the Projects page.
- Remote URLs are stored without credentials, so a token inside an https remote never reaches the database.

---

## Tests and CI

```bash
# lint · ruby (SQLite) · ruby-pg (PostgreSQL) · frontend · flake · audit · secrets · host, all in Docker
# (the env and the CPUs it needs: CONTRIBUTING.md § Tests)
CI_BASE_REF=origin/main CI_GITHUB_READ_TOKEN=$(gh auth token) CI_GITHUB_CACHE_DIR=~/.cache/busyyaks-ci scripts/ci/test.sh all
# RuboCop only (Cookpad's style guide); -a autocorrects
scripts/lint/rubocop [-a] [paths]
# pre-commit: overcommit in Docker — RuboCop, ESLint, Prettier, gitleaks, ShellCheck on the staged files
git config core.hooksPath .githooks
# once per worktree, and after a change to .overcommit.yml (signed config)
scripts/hooks/run sign
```

The suite runs in its own image, never touching a running deployment, on every CPU, with a coverage floor. The badges
at the top show the last green build of the default branch. Stages, parallelism, coverage and badges:
[`docs/TESTING.md`](docs/TESTING.md); lint rules and hooks: [`docs/LINT.md`](docs/LINT.md).
Two runners run the same script: **GitHub Actions** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml): every
pull request, forks included, and every push to `main`, on `ubuntu-latest`; check `gates` (workflow `ci`)) and **Jenkins**, the
maintainer's runner (the `Jenkinsfile`, status `jenkins/ci`, which also refreshes the badges). Any other CI that can
run Docker can run it too. The Actions job runs on public repositories only; a private copy (a private local repo, a private fork)
skips it — no minutes spent — unless its repository variable `CI_ON_PRIVATE` is `true`. While a repository is
private the check shows as skipped, and a skipped check satisfies a required one: there, require `gates` only with
`CI_ON_PRIVATE` set.

**Docker access = root.** `scripts/ci/test.sh` starts containers on the Docker daemon, and the Ruby stage mounts the
daemon's socket (`/var/run/docker.sock`) into a container (compose) that builds and runs the checkout's code as root.
Whoever controls that code controls the host: run it on a disposable machine (a GitHub-hosted runner) or on a CI host
that builds trusted branches only.


---

## Design rules

- **No fallbacks.** A missing env or config key stops boot; so does a missing `auth` provider (no auth is a choice you
  write down). A failed scan or GitHub read is recorded and shown next to the last good one. Nothing substitutes a
  default, a cached value or a guess.
- **Unknown is not zero.** A branch with no upstream has `unpushed` = unknown (shown `—`), and a day the PR search
  did not cover shows `—`, never 0.
- **Numbers come from the server.** Reports and pages show computed figures; a model never counts.
- **Agents never approve their own work.** Only the operator moves a card past Human Check.

---

## When not to use it

- **A team.** One operator: everyone the auth provider lets in sees and does the same; there are no roles beyond
  operator and agent.
- **Not Linux, no tmux, no Claude Code.** The launcher drives tmux, confirms sessions through `/proc`, and types only
  into Claude Code panes.
- **Public, with no identity provider.** `none` is for localhost; a public deployment needs a provider you write
  ([Sign-in](#sign-in)).
- **Repos spread over many machines.** The scanner reads one directory tree on the box it runs on.
- **A public endpoint for agents.** The MCP server is for local sessions only; never tunnel it.

---

## Hand it to a coding agent


The repo is built to be worked on by agents. A prompt to start from:

```text
Set up busyyaks (this repo) on this machine and get its tests green.
1. Read README.md and .env.example.
2. Run bin/setup (copies .env.example and the two config examples, writes the secrets and HOST_UID/HOST_GID, lists
   what is left), then fill .env and the configs for this box (launch.commands: the invocations an agent launcher may
   be, as in the example; the launchers themselves are set on Settings → Agents & launchers):
   PROJECTS_ROOT = <dir holding my repos>, GITHUB_LOGIN = <login>, GITHUB_TOKEN = a read-only token,
   TEAM_TERMINAL_URL + SSH_ATTACH_TEMPLATE (ask me: they point at my own tools / host name);
   keep `auth: { provider: none, allow_unauthenticated: true }` (localhost) and `agents: { collector: none }` unless I name a collector.
   LAUNCHER_RUN_DIR = ~/.local/state/busyyaks/run written out (persistent; outside this checkout and PROJECTS_ROOT).
   Ask me for anything you cannot fill.
3. Run scripts/ci/test.sh all (Docker only; install nothing on the host) and report pass/fail counts.
4. bin/setup check && docker compose up -d --build --wait web mcp scanner github notifier;
   check http://127.0.0.1:$WEB_HOST_PORT/up is 200.
Do not edit vendor/agents_kanban or frontend/src/vendor: they are vendored copies.
```

Tools for agents working on busyyaks itself: `bin/qa-cookie` prints a signed-in session cookie for headless browser
QA, and `bin/rename-project` moves a project's slug in the database after a repo rename.

---

## Documentation

| Doc | |
|---|---|
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | localhost (default), same-host nginx + TLS, or an frp tunnel |
| [`docs/AUTH.md`](docs/AUTH.md) | writing an auth provider |
| [`docs/DAILY-REPORT.md`](docs/DAILY-REPORT.md) | how the daily report runs, tick by tick |
| [`docs/TESTING.md`](docs/TESTING.md) · [`docs/LINT.md`](docs/LINT.md) | test stages, parallelism, coverage · lint rules and git hooks |
| [`docs/API-kanban.md`](docs/API-kanban.md) | the board's HTTP API |
| [`vendor/agents_kanban/SPEC.md`](vendor/agents_kanban/SPEC.md) | the kanban module's contract |
| [`.env.example`](.env.example) · [`config/busyyaks.example.yml`](config/busyyaks.example.yml) · [`config/kanban.example.yml`](config/kanban.example.yml) | every setting |


---

## Contributing

Issues and pull requests are welcome: [CONTRIBUTING.md](CONTRIBUTING.md) has the setup (hooks included), the checks a
pull request must pass (`scripts/ci/test.sh all` green; it needs only Docker, and access to its socket is root on that
machine — see [Tests and CI](#tests-and-ci); the same gates run on your PR in GitHub Actions), the vendoring rule
(kanban module changes go to [busyyaks_agents_kanban_module](https://github.com/robertziel/busyyaks_agents_kanban_module)
first) and the commit style. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Changes:
[CHANGELOG.md](CHANGELOG.md).

## Security

Report a vulnerability privately, never in a public issue: [SECURITY.md](SECURITY.md) has how, what is supported and
what is in scope. Keep the MCP endpoint local and `provider: none` on localhost.

---

## License

[Apache License 2.0](LICENSE). Inter and Fragment Mono (`public/static/fonts/`) are under the SIL Open Font License
1.1. The vendored kanban module (`vendor/agents_kanban`, `frontend/src/vendor/agents_kanban`) is Apache-2.0 too; each
copy carries its `LICENSE`. The RuboCop rules in `config/rubocop/cookpad.yml` are Cookpad's style guide, CC BY 3.0;
`lib/busyyaks/agent_screen.rb` is a port of herdr's screen detection, Apache-2.0. Sources and paths: [NOTICE](NOTICE);
dependency licenses: [docs/DEPENDENCY-LICENSES.md](docs/DEPENDENCY-LICENSES.md).
