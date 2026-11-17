# Deploying busyyaks

busyyaks binds every port to `127.0.0.1`. **The default is localhost only:** run it on the machine where you work
and open it in the browser there. You need no reverse proxy, no TLS and no `deploy/` file for that.

| Mode | Who reaches the dashboard | What you set up | `.env` "Reverse proxy" keys |
|---|---|---|---|
| **1. Localhost** (default) | browsers on this machine (or through your own SSH tunnel) | nothing beyond the [Quickstart](../README.md#quickstart) | leave empty |
| **2. Same-host nginx + TLS** | anyone who can reach the host on 443 (the sign-in gate still applies) | nginx on the busyyaks host | `PUBLIC_HOST`, `TLS_CERT_PATH`, `TLS_KEY_PATH`, `PROXY_UPSTREAM` |
| **3. Tunnel to a public proxy host** | same as 2, but the busyyaks host needs no public IP or open port | frpc on the busyyaks host, frps + nginx on a public server | all of mode 2, plus `FRPC_SUBDOMAIN` |

Every mode is **web only**: the MCP port (`MCP_HOST_PORT`) is never proxied or tunnelled. Agents reach it on
`MCP_HOST` (`.env`, a loopback address). Sign-in is the auth provider in `config/busyyaks.yml` `auth` ([Sign-in](../README.md#sign-in)): mode 1
may run `provider: none` with `allow_unauthenticated: true` (no sign-in; every boot logs `AUTH DISABLED`); modes 2 and 3 expose the dashboard, so they need a provider that signs people
in — with `none`, anyone who reaches the host is the operator. A provider talking to an external identity service must
have it allow the origin the browser uses: `http://127.0.0.1:<WEB_HOST_PORT>` in mode 1, `https://<PUBLIC_HOST>` in
modes 2 and 3. The session cookie's `Secure` flag is `.env` `SESSION_COOKIE_SECURE`: `false` in mode 1 (plain http),
`true` in modes 2 and 3 (the browser talks https to nginx).

### Hosts the web app answers (DNS rebinding)

A page on another site can re-resolve its own name to `127.0.0.1` ("DNS rebinding"); the operator's browser then
treats it as same-origin with busyyaks and could read the CSRF token and drive the operator API — launches, comments
typed into agent sessions, dialog answers. Its requests still carry `Host: <its name>`, so the web app
(`lib/busyyaks/host_guard.rb`, in front of every route and asset) answers only these Hosts and refuses every other one
with **421**, before any handler runs:

| Host | origin | from |
|---|---|---|
| `127.0.0.1:<WEB_HOST_PORT>`, `localhost:<WEB_HOST_PORT>` | `http://…` | mode 1, an SSH tunnel on the same local port, QA |
| `<PUBLIC_HOST>` (when set) | `https://…` | modes 2 and 3 (nginx forwards `Host: <PUBLIC_HOST>`) |

A mutation (anything but GET/HEAD) that sends `Origin` — or, without it, `Referer` — must name its Host's own origin
(above), else **403**; the CSRF token is checked behind it either way. `X-Forwarded-Host` is never read. Both values are
`.env` keys with no default: `WEB_HOST_PORT` required, `PUBLIC_HOST` present (empty = loopback only); a missing or
malformed one stops the boot. `provider: none` with a non-empty `PUBLIC_HOST` stops the boot too: no sign-in answers
loopback only. An SSH tunnel must keep the port (`-L <WEB_HOST_PORT>:127.0.0.1:<WEB_HOST_PORT>`): another local port
is another Host, refused.

## 1. Localhost (default)

```bash
docker compose up -d --build web mcp scanner github notifier
```

Then open `http://127.0.0.1:<WEB_HOST_PORT>` in a browser.

To reach it from another machine without exposing it, use an SSH tunnel:
`ssh -L <WEB_HOST_PORT>:127.0.0.1:<WEB_HOST_PORT> <busyyaks-host>`, then open `http://127.0.0.1:<WEB_HOST_PORT>`
on the machine you ran ssh from.

## Rendering the proxy files (modes 2 and 3)

`deploy/` holds templates only: `nginx-busyyaks.conf.template` and `frpc-busyyaks.ini.template`. Each `{{NAME}}`
placeholder is filled from `.env` by `bin/render-deploy`, which writes to `deploy/rendered/` (gitignored), so your
hosts, ports and certificate paths never enter the repo.

```bash
bin/render-deploy          # every template (mode 3)
bin/render-deploy nginx    # only the nginx vhost (mode 2); `frpc` = only the tunnel block
```

A file from an earlier run that this run did not render stays in `deploy/rendered/` and is listed as such.
`deploy/rendered/` is kept out of git (`.gitignore`) and out of the Docker images (`.dockerignore`).
Values must be plain: `# comment` after a value is dropped and `"…"` / `'…'` quotes are removed, as compose does. A value
with `$` (interpolation), a backslash escape, an unclosed quote or a quote inside it is refused, naming the key. Each value
is also checked for its shape before it is written: `PUBLIC_HOST` a hostname, `FRPC_SUBDOMAIN` one DNS label,
`PROXY_UPSTREAM` `host:port` (hostname, IPv4 or `[IPv6]`), `WEB_HOST_PORT` and every port 1-65535, the TLS paths absolute with no spaces, `;`, braces, quotes or `$`.

If a placeholder has no value in `.env`, it exits 1 with the name (`nginx-busyyaks.conf.template: missing in .env:
PUBLIC_HOST`) and writes nothing. It never uses a default.

| Placeholder | From | Notes |
|---|---|---|
| `PUBLIC_HOST` | `.env` | the hostname nginx serves (`server_name`) |
| `TLS_CERT_PATH`, `TLS_KEY_PATH` | `.env` | certificate and key on the proxy host (e.g. certbot's `/etc/letsencrypt/live/<host>/…`) |
| `PROXY_UPSTREAM` | `.env` | `host:port` nginx forwards to: mode 2 `127.0.0.1:<WEB_HOST_PORT>`; mode 3 frps' `vhost_http_port` |
| `FRPC_SUBDOMAIN` | `.env` | mode 3: the subdomain under frps' `subdomain_host` (the frpc template also uses `PUBLIC_HOST`, which must equal `<FRPC_SUBDOMAIN>.<subdomain_host>`) |
| `WEB_HOST_PORT` | `.env` | the frpc `local_port` (same value compose publishes) |
| `NGINX_MAX_BODY` | derived | `ceil(ATTACHMENT_MAX_BYTES / 1 MiB) + 5` MiB, so card uploads are not cut off by nginx's 1m default. Never set it in `.env` (refused); a non-numeric `ATTACHMENT_MAX_BYTES` is an error naming it |

Templates target nginx with HTTP/2 (`listen 443 ssl http2`; nginx ≥ 1.25.1 logs a deprecation warning) and frp's INI
client format (frp 0.52+ still reads it and logs it as deprecated).

## 2. Same-host nginx + TLS

```bash
# .env: PUBLIC_HOST=dash.example.com, TLS_*_PATH=…, PROXY_UPSTREAM=127.0.0.1:<WEB_HOST_PORT>
bin/render-deploy nginx
sudo cp deploy/rendered/nginx-busyyaks.conf /etc/nginx/sites-available/dash.example.com
sudo ln -sf /etc/nginx/sites-available/dash.example.com /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

The app's own gate (the auth provider, asked on every request) is the access control. A provider whose browser flow
POSTs a token exchange cannot pass an HTTP basic-auth prompt, so do not put one in front of the vhost.

## 3. Tunnel to a public proxy host (frp)

This is the setup for a box at home or behind NAT: the busyyaks host runs `frpc`, and a public server runs `frps`
(with `subdomain_host`) and nginx.

**frps routes by the Host header.** nginx forwards `Host: <PUBLIC_HOST>`, so `PUBLIC_HOST` must be
`<FRPC_SUBDOMAIN>.<frps subdomain_host>` (e.g. `busyyaks.home.example.com` with `subdomain_host = home.example.com`).
Anything else gets frps' 404.

```
browser ─https─▶ nginx (public server, PUBLIC_HOST) ─▶ frps vhost_http_port (= PROXY_UPSTREAM)
                                   ─tunnel─▶ frpc (busyyaks host) ─▶ 127.0.0.1:WEB_HOST_PORT
```

```bash
# .env: mode 2's keys with PROXY_UPSTREAM=127.0.0.1:<frps vhost_http_port>, plus FRPC_SUBDOMAIN=busyyaks
bin/render-deploy
# busyyaks host: append deploy/rendered/frpc-busyyaks.ini to frpc.ini, restart frpc
scp deploy/rendered/nginx-busyyaks.conf <public-server>:/tmp/
# public server (root): cp /tmp/nginx-busyyaks.conf /etc/nginx/sites-available/<PUBLIC_HOST>, then the ln + reload of mode 2
```

## The host launcher and the daily report's token

| | |
|---|---|
| socket | `bin/launcher` (systemd `--user`, `deploy/install-launcher.sh`) listens on `$LAUNCHER_RUN_DIR/launcher.sock` (mode 0600, the dir 0700; its clone logs live there too). `.env` `LAUNCHER_RUN_DIR`: absolute, outside (and not around) `PROJECTS_ROOT` and the checkout — containers mount those, and a `:ro` mount does not stop a `connect()` to a socket — owned by `HOST_UID`; the launcher and the installer refuse anything else (`LauncherRules.run_dir!`): the path as written must be its real path (no symlink anywhere in it — compose mounts the path as written), its parent must be owned by `HOST_UID`, and no ancestor may be writable by group / other (a sticky `/tmp` included); an existing dir owned by another uid or open to group / other is refused, never repaired. The launcher creates it 0700 at start. Compose mounts it at `/launcher` into **web · mcp · notifier only**, `create_host_path: false`. It is a **persistent** dir, e.g. `~/.local/state/busyyaks/run` written out. Across a launcher restart or a reboot (daemon restart) those three keep running or come back by their restart policy, and the launcher replaces the stale socket in the same dir when it starts. Calls fail with ECONNREFUSED until then, and nothing needs the operator (checked in a throwaway dind: daemon restart → `running restarts=0`, `ok` once the launcher is up). A dir that does not exist stops them: `bind source path does not exist`, and Docker does not retry that (create it, then `docker compose up -d`) |
| collector | `bin/collector` (systemd `--user`, `deploy/install-collector.sh`; README § Agent sessions) writes `config/busyyaks.yml` `agents.collector.snapshot` and listens on `read_socket` (0600), both in one dir it creates 0700 under the same rule as `LAUNCHER_RUN_DIR` (`LauncherRules.run_dir!`) and outside `LAUNCHER_RUN_DIR` too: its `send` types into sessions, so no container mounts it — only the host launcher reads it. It reads this uid's tmux servers only and `/proc` stat / cmdline / cwd / exe, never a process environment; what leaves is the snapshot's allowlisted fields, never a pane's contents or its argv as such — only the model and effort read from it, shape-checked (`screen` answers the launcher alone). `send` pastes only into a pane whose snapshot agent still runs (same pid AND start time), never while a dialog is on its screen, the text stripped of control characters and handed to tmux through stdin |
| git | the git busyyaks runs in a repo it does not control (scanner, launcher, MCP churn) carries `Busyyaks::SafeGit`'s flags: defence in depth, **not a boundary**. A repo's config can name programs in ways no flag list covers (known: a filter whose name holds `=`). Isolating that git is a separate design |
| daily token | `MCP_REPORT_TOKEN` (≥ 32 chars, ≠ `MCP_TOKEN`): `bin/daily-report`, `deploy/install-daily-timer.sh` and the runner use it; it lists and calls only `McpServer::REPORT_TOOLS` |

Upgrading a deployment whose socket was `./data/run/launcher.sock` — every config / env key first: the launcher and
every container refuse to start while one is missing:

```bash
openssl rand -hex 32                              # → .env MCP_REPORT_TOKEN=<it>
printf '\nLAUNCHER_RUN_DIR=%s\n' "$HOME/.local/state/busyyaks/run" >> .env   # persistent; outside PROJECTS_ROOT and the checkout
printf '\nLAUNCHER_STATE_DIR=%s\n' "$HOME/.local/state/busyyaks/launcher" >> .env   # § Folder trust; outside every container mount
$EDITOR config/busyyaks.yml                       # owner_remotes: host/owner prefixes ("github.com/you/"); an old
                                                  # substring entry ("you/") now stops the boot: it could never match;
                                                  # add  launch: { trusted_paths: [/projects/<repo>, …] }  (repo roots
                                                  # you trust; [] for none; § Folder trust)
                                                  # and  launch: { start_seconds: 30 }  (required,
                                                  # 1..600: how long a launch waits for its agent to
                                                  # come up; missing → the launcher refuses to start)
deploy/install-launcher.sh                        # creates both dirs (0700), restarts the launcher on the new socket
docker build -t busyyaks:local . && docker compose up -d --no-build web mcp notifier scanner github   # new mounts + env
# ("dependency failed to start": web was not healthy in time — a long migration; run the same `up` again once /up answers)
deploy/install-daily-timer.sh                     # the timer, checked with the new token
rm -rf data/run                                   # the old socket dir: nothing reads it any more
```

### Remaining risks

| | |
|---|---|
| shared database | scanner and github write the database by design (scan results, GitHub snapshots), with the same file / server as web, mcp and notifier. What is typed into a session is a `card_pings` row the notifier delivers; busyyaks writes those only through the engine's `Store` (`test/unit/ping_writers_test.rb`), never from collector data. A collector that is itself compromised (code execution in its container) can still write that row: the database is one trust zone. Per-service database credentials would split it. Open |
| daily runner's git | the runner's `git -C <repo> …` runs on the host, driven by a model that reads untrusted text, with SafeGit's environment only (pager `cat`, `diff.external` blanked). A repo-config `diff.<x>.textconv` (`log -p`), `diff.<x>.command` (`--ext-diff`) or `filter.<x>` (`status`) still runs there as the operator. Open |
| git on untrusted repos | busyyaks runs the git CLI on repos it does not control in: the scanner container, **mcp** (the full scan through `scan_now` — the operator's own `MCP_TOKEN` only — and, under the daily report's token too, the daily facts' churn and the report rendering's card links in `check_report` / `post_report`) and **web** (the kanban engine's card links: plain git, without SafeGit's flags), and on the host in the launcher. SafeGit's flags are defence in depth only. A program a repo's own `.git/config` names in a way the flags miss (known: a filter name holding `=`. A promisor lazy fetch is turned off by `GIT_NO_LAZY_FETCH=1` plus `protocol.allow=never` and `protocol.<file|ssh|git|http|https|ext>.allow=never` in command scope (a repo's own `protocol.<name>.allow=always` beats the bare `protocol.allow`, not the named keys) — set by SafeGit for its own calls and, for every git in the containers including the engine's card links, in docker-compose.yml's `x-app` environment; on the host the launcher's git gets them from SafeGit; still only flags) runs with that process's access. mcp and web hold the launcher socket, so for them that is a path to the host (launch / type into a session as the operator); the scanner and github containers do **not** mount the socket (`test/unit/compose_test.rb` `test_launcher_socket_reaches_only_web_mcp_and_notifier`) but write the database (see shared database). Open, and a blocker for the beta: reading repos with a library that runs no repo-configured program (libgit2) removes this from mcp, web, the scanner and the launcher |
| dialog answers | the launcher's `answer` op presses a key on any dialog a session shows — Claude Code's folder-trust prompt included — when the caller sends the dialog's current hash, which its `dialog` op returns. The web UI calls it for the operator only, but any client of the launcher socket (web · mcp · notifier, and code running in them) can call both ops: a prompt "left for the operator" is not a boundary against those containers. The socket mount is the boundary (§ git on untrusted repos). Open |
| a hung git | a repo whose `.git` holds a FIFO (or anything git blocks reading) hangs the git that reads it, with no per-git timeout: the scanner's whole scan, a `scan_now` or churn in mcp, and the request in web (the kanban card links) that reads that repo. Open until repos are read with a library instead of the git CLI |
| terminals | an open terminal shows the agent's screen to the browser, and in control types into it as the operator. The checks are the web's session + Origin + registration and the launcher's running-agent check; the launcher cannot read the database, so any client of the launcher socket (web · mcp · notifier, and code running in them) can call `attach` on any running agent session — the socket mount is the boundary, as for dialog answers. `attach` adds reading the screen to what such a client already has: `notify` types up to 8000 characters + Enter into any running agent session and `stop` ends one, with no registration check either (the launcher reads no database: every service writes it, so a row there would be no proof). Through `PUBLIC_HOST` only with `terminal.public_host: allow`. Open |

## Agent settings (launchers + agent types) and the command allowlist

the launchers (the commands that start an agent session) and the agent types live in the database (table
`agent_settings`, one row per saved revision, the newest is current), edited on **Settings → Agents & launchers**
(the header's cog). `config/kanban.yml` no longer holds them — a file that still has `launchers` / `agent_types` stops
the boot with the steps below.

- **Allowlist** — `config/busyyaks.yml` `launch.commands` (required): the whole INVOCATIONS a launcher may be on this
  host, each exactly `{kind, command, args, via_shell}`, e.g.
  `- { kind: claude_code, command: claude, args: ["--permission-mode", "bypassPermissions"], via_shell: false }`.
  A launcher must equal one entry: the Settings page offers only these (a dashboard user picks one and names it), a
  save of anything else is refused (422), and `bin/launcher` refuses to start one (it rebuilds the engine config from
  the revision each launch carries and checks it again). So no dashboard user can add an argument you did not list —
  a `--settings` with hooks, an `--mcp-config`, a permission mode. A host file, read-only in the containers. Never list
  a shell or an interpreter (`bash`, `sh`, `python`) as a command. What stays editable on the page is the model id
  (the engine's model alphabet: no option can hide in it) and the prompt, which is ONE argv word and refused when it
  starts with `-` (as a template and as rendered), so it cannot become an option of the command either: it is what
  the session is told, the reach a card comment to that session already has. After an edit:
  `deploy/install-launcher.sh` (the launcher reads it at start) and restart web.
- **Kinds** — `claude_code` (Claude Code: `--model`, the prompt, `--remote-control <session>` last; the launcher checks
  that process came up) or `hermes` (Hermes Agent, args `[chat]`: `-m <model>`, `-q <prompt>`; no remote control —
  the launcher checks the pane runs the command, so a hermes launcher must not be `via_shell`).
- **Moving an existing deployment** — ONE maintenance window: the old code refuses the new `launch.commands` key and
  the new code refuses the old `launchers` / `agent_types` keys, so nothing may restart between the edits and the new
  image being up. In this order:
  1. back up the database (§ The database) and both files:
     `cp config/kanban.yml data/backups/kanban-pre-agent-settings.yml; cp config/busyyaks.yml data/backups/busyyaks-pre-agent-settings.yml`;
  2. build the new image (`docker build -t busyyaks:local .`) — nothing restarts yet;
  3. stop what starts sessions: `docker compose stop notifier` and `systemctl --user stop busyyaks-launcher`;
  4. add `kind: claude_code` to each launcher in `data/backups/kanban-pre-agent-settings.yml` (the copy that gets imported);
     add `launch.commands` to `config/busyyaks.yml`: one entry per launcher in that copy, its exact
     `{kind, command, args, via_shell}`; delete `launchers:` and `agent_types:` (with their comments) from
     `config/kanban.yml`;
  5. `docker compose up -d --no-build web` (it migrates: the first revision is the template, plain `claude`), then
     `docker compose exec -T web bin/agent-settings import < data/backups/kanban-pre-agent-settings.yml`;
  6. `docker compose up -d --no-build mcp scanner github notifier` and `deploy/install-launcher.sh` (the launcher on
     the new code); Settings → Agents & launchers shows the imported revision and the argv of every type × launcher.
- **Rollback** — inside the window, before step 6: restore the two backed-up files and the database backup, then
  `docker compose up -d` the previous image and `deploy/install-launcher.sh` from the previous checkout. After the
  window: `bin/agent-settings show > data/backups/agents-<date>.yml` first (the launchers + agent types as YAML) — the
  migration's `down` drops the table and every revision; put them back into `config/kanban.yml` (without `kind`, which
  the old engine refuses) and drop `launch.commands` from `config/busyyaks.yml`.

## The board theme (`config/kanban.yml` `theme`)

Every `--ak-*` token the vendored engine's `frontend/src/vendor/agents_kanban/styles/kanban.css` declares in a
`.ak-root` rule must have a value in `theme`. At boot `Busyyaks::Kanban.check_theme!` reads the token list from that
CSS and refuses to start (web, mcp, notifier) naming each missing token — the board never falls back to the engine's
built-in colours. `config/kanban.example.yml` maps them all; a re-vendor that adds a token adds it there too.

**Upgrading to the working glow**: before the restart, add these two lines under `theme:` in the live
`config/kanban.yml` — without them the boot is refused:

```yaml
  --ak-working: var(--working)
  --ak-step-overhang: 12px
```

## Lead-first boards: upgrading a deployment

A board starts with its lead (the Launch bar, never automatic) and only the lead starts its team (`kanban_spawn`).
The lead key is a guard against cooperative agents starting sessions without their lead, not authentication: every
agent shares one MCP bearer and can name any tmux session (binding a caller needs per-session MCP tokens).
Nothing restarts a lead: a lead that ends for any reason but your Stop is on the waiting alert, and the board says "no
lead: press Launch".

**One new required host key**, in the gitignored `config/busyyaks.yml` (the launcher and every service refuse to
start without it):

```yaml
launch:
  # each agent session in its own systemd user scope, or null when the host runs no systemd user manager
  scopes: { lead_oomd: avoid, session_memory_max: null }   # session_memory_max: e.g. 16G for every non-lead session
```

`lead_oomd: avoid` MARKS a lead's scope `ManagedOOMPreference=avoid` (its cgroup gets `user.oomd_avoid=1`); per
systemd.resource-control(5) systemd-oomd then prefers other candidates. Not verified under real memory pressure.

**Order** (each step checked before the next):

1. Back up the database (§ The database).
2. Add `launch.scopes` to `config/busyyaks.yml`, and delete `lead_key_env` from `config/kanban.yml` if an earlier
   build of this change put it there (the engine refuses unknown keys: boot fails naming it).
3. `docker build -t busyyaks:local .`, then **restart the launcher** (`deploy/install-launcher.sh`). The new
   launcher keeps a lead's key in `LAUNCHER_STATE_DIR/leads.json` (0600, launcher-only). A lead started by the OLD
   launcher is not in that record and cannot `kanban_spawn`: stop it and Launch it again after step 5.
4. **Migrate**: `bin/web` runs `20261207463000` on start (engine Schema v12: `agent_sessions.lead_id`, `needs_lead`,
   `lead_key_digest` and `CHECK (needs_lead = 0 OR lead_id IS NOT NULL)`), and writes the current agent settings as
   a NEW revision in the lead-first shape: `spawns_for` / `spawn_launcher` / `launcher_follows` removed, the lead takes
   the work column types `spawns_for` named, each follower / spawner runs `under` the lead, a plain type (no prompt,
   takes nothing) becomes `standalone`. A revision it cannot convert (no lead to name, or a prompted type under none)
   stops the migration with the reason: fix it on Settings → Agents & launchers on the old version, then deploy again.
   The old revision stays in the history.
5. `docker compose up -d --no-build web mcp scanner github notifier`, `/up` 200, MCP `tools/list` lists
   `kanban_spawn`, then Launch each board's lead.

Rollback (`20261207463000` down): refused while a session under a lead is open, or while a revision saved on top of
the migration's uses `under` / `standalone` (import a pre-463 revision with `bin/agent-settings import` first: that one
stays the newest). With no later revision it writes the one from before the migration as the newest again; then it
drops the three columns.

## Runtime settings (the services' timing)

How often each service works is a revision in the database, edited on **Settings → Runtime**
(`/settings/runtime`, the cog menu) or `docker compose exec -T web bin/runtime-settings show | import < file.yml |
import-env < .env`. Every service reads the current revision at its next turn: a save applies without a restart.

| key | was `.env` | read by |
|---|---|---|
| `scan_interval_seconds` | `SCAN_INTERVAL_SECONDS` | scanner (sleep), mcp (`last_scan` stale after 3 ×) |
| `github_interval_seconds` | `GITHUB_INTERVAL_SECONDS` | github (network, feed, merged PRs) |
| `github_ci_interval_seconds` | `GITHUB_CI_INTERVAL_SECONDS` | github (PR / CI polls), web + mcp + notifier (stale after 3 ×, window 10 ×), the webhook |
| `notifier_interval_seconds` | `NOTIFIER_INTERVAL_SECONDS` | notifier (ping delivery) |
| `notifier_watch_seconds` | `NOTIFIER_WATCH_SECONDS` | notifier (watch pass) |
| `watchdog_grace_seconds` | `WATCHDOG_GRACE_SECONDS` | notifier, web, mcp (launch / watchdog grace) |

- Each a whole number of seconds 1..86400; the watch pass (`notifier_watch_seconds` rounded up to whole `notifier_interval_seconds` turns) below 10 × `github_ci_interval_seconds`. A refused save is 422 with the reason; nothing is written.
- Revision 1 = `config/runtime.template.yml` (migration `20261217523000`), the values `.env.example` shipped.
- **Upgrading** (`bin/setup check` refuses a `.env` that still has one of the six lines, so the import runs before it, on web alone — compose itself never runs the check):

  ```sh
  grep -E '^[[:space:]]*(export[[:space:]]+)?(SCAN_INTERVAL|GITHUB_INTERVAL|GITHUB_CI_INTERVAL|NOTIFIER_INTERVAL|NOTIFIER_WATCH|WATCHDOG_GRACE)_SECONDS=' .env > data/runtime-env.bak
  docker build -t busyyaks:local . && docker compose up -d --no-build --wait web    # migrates: revision 1 = the template
  docker compose exec -T web bin/runtime-settings import-env < data/runtime-env.bak  # revision 2 = your values
  sed -i -E '/^[[:space:]]*(export[[:space:]]+)?(SCAN_INTERVAL|GITHUB_INTERVAL|GITHUB_CI_INTERVAL|NOTIFIER_INTERVAL|NOTIFIER_WATCH|WATCHDOG_GRACE)_SECONDS=/d' .env
  bin/setup check && docker compose up -d --no-build mcp scanner github notifier
  ```

  Only web runs between the migration and the import (seconds), and the services that loop on these values start after it. Your values equal `config/runtime.template.yml` → the import adds an identical revision; skipping it is the same.
- Rollback: the previous release reads the six keys from `.env` again — put the lines back from `data/runtime-env.bak`.

## Skills (what a launched session is told)

busyyaks's board workflow is a set of skills, handed to each session busyyaks launches or spawns — **for that session
only**. Nothing is installed user-wide: a `claude` or `hermes` you start yourself on this host sees none of them.

No manifests — the shape of a layer is the rule. Every layer is a dir of the same shape:

| layer | where | committed in |
|---|---|---|
| busyyaks's own | `skills/busyyaks/` of this checkout | busyyaks |
| this deployment's | `config/busyyaks.yml` `skills.local_dir`, or `null` | this checkout |
| a project's | `<repo>/.busyyaks/skills/` | that repo — loaded only when `skills.project: allow` and the repo is trusted (row Folder trust); else the launch says `project_skills: left: <why>` and reads none of it; a leftover `.busyyaks/skills.yml` (the old manifest) leaves them too, named |

| in a layer | what | loads for |
|---|---|---|
| `core/SKILL.md` (+ reference `.md` files) | how a session works with the board and the kanban MCP. busyyaks's layer only, required | every session busyyaks starts, `plain` included |
| `agents/<type>.md` | what a session of that agent type does (`lead.md`, `worker.md`, `team.md` — the agent settings' type KEYS; another file name is refused) | sessions of that type; each layer's file is appended after busyyaks's, in layer order |
| `<name>/SKILL.md` (+ `.md` files) | an on-demand skill (e.g. `reviewer`) | every session: listed in the entry skill by the name its CLI loads it with (hermes: `busyyaks-<name>-<token>`), loaded when the work needs it. A name another layer has, `core`, `agents` or `session` is refused |

A skill = regular `.md` files, `SKILL.md` with frontmatter exactly `name` (= its dir) + `description`. The entry skill
`session` the session opens with = core, then `agents/<type>.md` of each layer, then the on-demand list; core's
reference files are staged beside it.

An `agents/<type>.md` names a type of the CURRENT agent settings: removing a type from Settings → Agents & launchers
while a layer still has its file refuses every launch with that file named — delete the file in the same change.

**Updates need no install**: `bin/launcher` reads the layers at every launch, so a change merged into this checkout
(or committed in a repo) reaches the next session started; a running session keeps the copy it started with (its sha
is in the launch result).

Per launch, `bin/launcher` selects the type's skills, validates them (a missing core, an `agents/` file for no agent
type, a stray file, a link, a size over `skills.max_bytes` / `max_start_bytes`, a skill named like another layer's →
the launch is refused, nothing started), stages a copy in `LAUNCHER_STATE_DIR/skills/<session>/` (0700; removed once the session is gone) and hands it
to the CLI:

| kind | how | checked after the start |
|---|---|---|
| claude_code | `--plugin-dir <stage>` (plugin `busyyaks`) + the prompt opens with `/busyyaks:session` | the `claude` process's argv carries `--plugin-dir <stage>` |
| hermes | `tmux new-session -e BUSYYAKS_SKILLS_DIR=<stage>` + `-s busyyaks-session`; the skills in `<stage>/busyyaks-skills/`, reached by the line `- ${BUSYYAKS_SKILLS_DIR}/busyyaks-skills` under `skills.external_dirs` of hermes's `config.yaml` | `hermes skills list`, run in the session process's own environment (its `HERMES_HOME`, its variable), lists `busyyaks-session`; else killed + refused with the file and the line to add |

Hermes, measured on v0.21.5: an `external_dirs` entry passes `os.path.expandvars`, a relative one is anchored at
`HERMES_HOME`, a missing dir is skipped. So for every run busyyaks does not start (variable unset) the line stays
literal and points nowhere; set empty it is `/busyyaks-skills`, nothing either. (A bare `${BUSYYAKS_SKILLS_DIR}` line
would be `HERMES_HOME` itself when empty: do not use it.) `-s` naming a skill hermes cannot find makes it exit with
"Unknown skill(s)", which the start check reports as a failed start.

An agent that comes up without its stage (a launcher function that drops the flags) is killed and the launch refused.
No skill may be a symlink or pass through one (every path component under the checkout / the repo is checked, and
its real path stays inside), and no skill file may hold Claude Code's `` !`command` `` syntax (it runs the command
when the skill loads): refused with the file and line, never stripped. `skills.project: allow` still means a trusted
repo's committers write text the launched agent follows — the same trust its `.claude/` settings already have.
The launch result and the launcher log name each skill with its source, load and sha256.

Setup: add `skills:` to `config/busyyaks.yml` (example in `config/busyyaks.example.yml`), and for hermes launchers the
line `- ${BUSYYAKS_SKILLS_DIR}/busyyaks-skills` under `skills.external_dirs` of the `config.yaml` hermes reads; restart
the launcher.

## Folder trust (the launcher)

The launcher answers Claude Code's "Yes, I trust this folder" prompt, which lets the repo's `.claude` settings, hooks
and `.mcp.json` run, only for a repo trusted from outside the repo:

| | |
|---|---|
| `config/busyyaks.yml` `launch.trusted_paths` | repo roots you list (a `.git` in each): container paths under `PROJECTS_MOUNT`, each exactly that dir, never what lies under it. Required (`[]` for none); the launcher refuses to start on one that is missing, not a repo root, or resolves outside `PROJECTS_ROOT`. Read at launcher start: after an edit, `deploy/install-launcher.sh` |
| made by the launcher | a "new repo" (`git init`) only — **never a clone**, an `owner_remotes` URL or a fork under your own name included: what a URL serves is whoever owns it. At the init the launcher writes a random nonce (32 bytes, hex) to the repo's `.git/busyyaks-created` (0600) and records it in `.env` `LAUNCHER_STATE_DIR/created.json`; the repo is trusted while that file holds the recorded nonce. A repo removed and made again at the path has no nonce (or another): not trusted, its entry dropped. `LAUNCHER_STATE_DIR` is the launcher's own: 0700, outside every container mount. A record it cannot read refuses the launch before a session starts |
| anything else | the prompt stays on screen (`trust: left`), every clone included: the launch flash says so, and a card the session owns gets it as a session dialog. Spawned workers stop on it too, for every repo not listed |

The clone: the URL is parsed strictly (`https://<host>/<owner>/<repo>[.git]` or `git@<host>:<owner>/<repo>[.git]`, plain
names only, no `.`/`..`, userinfo, port, query, fragment or `%`) and git gets only the URL rebuilt from those parts;
https / ssh only (`protocol.allow=never` otherwise), no hook, no submodule, no LFS download, and an environment of
only `PATH`, an empty `HOME`, `SSH_AUTH_SOCK` / `LANG` when set, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`,
an empty `GIT_TEMPLATE_DIR` and `GIT_LFS_SKIP_SMUDGE=1` (nothing else of the launcher's environment) — so an `insteadOf`
or a `protocol.<x>.allow` in your own gitconfig or environment cannot change where it reads from. **ssh is the supported
route for a private repo** (it still finds your keys); an https clone that needs a credential helper does not
authenticate.

**Claude Code's own trust list.** Claude Code remembers an answered prompt per path in `~/.claude.json`: a path once
trusted (by you, or by the launcher) stays trusted for Claude Code whatever busyyaks later decides. busyyaks never reads
or writes that file. Revoking a path = removing its entry there. A repo removed and made again at a trusted path is
trusted by Claude Code again; doing that needs write access under `PROJECTS_ROOT`, which already allows planting hooks
in any repo, so it is not a new capability — but it is not something busyyaks can close.

Upgrading: `launch:` and `LAUNCHER_STATE_DIR` are part of the one upgrade list in § The host launcher (keys first, then
the launcher, then build / up). Repos you launch that are not listed now stop on the prompt, spawned workers included, until you answer it once.

## The database

`.env` `DATABASE_ADAPTER` (required, no default; `.env.example`: `sqlite`) — `lib/busyyaks/database.rb`. Five processes
(web, mcp, scanner, github, notifier) write it; on both adapters write transactions run one at a time. Switching
adapters starts on an empty database, unless the data is copied (SQLite → PostgreSQL: the runbook below).

### SQLite (`DATABASE_ADAPTER=sqlite`)

`data/busyyaks.sqlite3` is written by five processes (web, mcp, scanner, github, notifier). Every connection
(`config/providers/db.rb`, `lib/busyyaks/sqlite.rb`) runs it in **WAL** journal mode, waits up to
`SQLITE_BUSY_TIMEOUT_MS` (`.env`, required) for another process's write lock, and opens every transaction with
`BEGIN IMMEDIATE` (the write lock up front, so a read-then-write never fails with "database is locked").

- `data/` must be a local file system (ext4, xfs, …). WAL shares memory between the processes through
  `busyyaks.sqlite3-shm`; a network file system (NFS, SMB) cannot do that. A connection that does not get WAL fails the
  boot.
- The database is three files while it runs: `busyyaks.sqlite3`, `-wal`, `-shm`. A plain file copy of
  `busyyaks.sqlite3` is a backup only with the five services stopped. A running database is backed up with
  `VACUUM INTO` (a consistent snapshot under WAL):
  `mkdir -p data/backups && docker compose exec -T web sqlite3 /data/busyyaks.sqlite3 "VACUUM INTO '/data/backups/busyyaks-$(date +%F-%H%M).sqlite3'"`.
- An existing database in the old `delete` journal mode switches on the first connection that gets it alone. While
  another process holds it, `PRAGMA journal_mode = WAL` waits `SQLITE_BUSY_TIMEOUT_MS`, then the boot fails with
  "database is locked" (the service restarts; nothing runs on the old journal). Switch it once, explicitly: stop the
  five services, back up the file, run
  `docker compose run --rm --no-deps web sqlite3 /data/busyyaks.sqlite3 "PRAGMA journal_mode = WAL"` (prints `wal`;
  the mode is kept in the file), then start them.
- Run those `sqlite3` commands as the services' user (compose `user:` = `HOST_UID:HOST_GID`, as above), never
  `--user root`: SQLite creates `-wal` / `-shm` next to the database, and root-owned ones would lock the services out
  (`bin/entrypoint` refuses to start on files in `data/` it does not own).

### PostgreSQL (`DATABASE_ADAPTER=postgresql`)

Sequel's `postgres` adapter (the `pg` gem, precompiled with its libpq). `.env`: `POSTGRES_HOST` (a host name, an
address, or a Unix socket directory), `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_LOCK_TIMEOUT_MS` — all
required; the password is passed as a connect option, never in a URL. The role must own the database (the migrations
create its tables when `web` starts: `bin/web` runs `hanami db migrate --no-dump`; run it by hand the same way —
`--no-dump`, as the dump would overwrite the committed SQLite `config/db/structure.sql`, and the image has no
`pg_dump`). Every transaction first sets `lock_timeout` = `POSTGRES_LOCK_TIMEOUT_MS`, then takes one advisory lock
(`pg_advisory_xact_lock`, `lib/busyyaks/postgres.rb`), so read-then-write transactions run one at a time as on SQLite,
and a writer behind a held lock fails after the bound ("canceling statement due to lock timeout") instead of waiting
forever.

- Your own server: point the keys at it. The services run on Docker's default bridge (`network_mode: bridge`), so a
  server on the host must listen on an address the containers reach.
- The compose `postgres` service: `.env` `COMPOSE_PROFILES=postgres` (every `docker compose up` starts it, and the app
  services wait until it is healthy), `POSTGRES_HOST=/data/postgres-run`, `POSTGRES_PORT=5432`, a DB / USER / PASSWORD
  of your choice (the image creates them on its first start). It runs as `HOST_UID:HOST_GID`; its cluster is
  `data/postgres`, its socket `data/postgres-run` — create both as that user before the first start
  (`mkdir -p data/postgres data/postgres-run`). It has no network: the app services reach the socket through their
  `data/` mount, and every login needs the password (`--auth-local=scram-sha-256`).
- Back up: `set -a; . ./.env; set +a; mkdir -p data/backups && docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres pg_dump -h /var/run/postgresql -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > "data/backups/busyyaks-$(date +%F-%H%M).pgdump"`
  (restore into an empty database with `pg_restore`).

### Switching SQLite → PostgreSQL (one time, the data moves)

`bin/db-copy-sqlite-to-postgres` (`lib/busyyaks/db_copy.rb`): refuses a target database that has any table, migrates
it with the app's migrations, refuses a SQLite file at another schema version, copies every table in foreign-key order
with its ids in one transaction, moves every id sequence past the copied ids, then verifies every table (row count +
SHA-256 over all rows) and fails on any difference. The SQLite file is opened read-only: it stays as it was, which is
the rollback. Attachments are files (`ATTACHMENTS_DIR`) and do not move. CI runs it on a fixture with rows in every
table (`test/unit/db_copy_test.rb`).

1. Stop the five services: `docker compose stop web mcp scanner github notifier`.
2. Back up the SQLite file: `mkdir -p data/backups && docker compose run --rm --no-deps web sqlite3 /data/busyyaks.sqlite3 "VACUUM INTO '/data/backups/busyyaks-pre-postgres-$(date +%F-%H%M).sqlite3'"`.
3. `.env`: `COMPOSE_PROFILES=postgres`, `DATABASE_ADAPTER=postgresql`, `POSTGRES_HOST=/data/postgres-run`,
   `POSTGRES_PORT=5432`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (`openssl rand -hex 32`),
   `POSTGRES_LOCK_TIMEOUT_MS=15000`. Keep `SQLITE_BUSY_TIMEOUT_MS` (the rollback uses it).
4. Build, create the dirs, start PostgreSQL alone: `docker build -t busyyaks:local . && mkdir -p data/postgres data/postgres-run && docker compose up -d --wait postgres`.
5. Copy + verify: `docker compose run --rm --no-deps web bin/db-copy-sqlite-to-postgres --from /data/busyyaks.sqlite3`
   — one `copied` and one `verified … rows  sha256 …` line per table, then `done: N tables, M rows copied and
   verified`. Any refusal or difference exits non-zero, nothing committed: the target is untouched (a non-empty
   target, a missing file), or migrated with only the migrations' own rows (a schema-version refusal, a value that does not fit its column, a difference).
   The copy only runs into a database without tables: fix, then drop and recreate the target database (or stop
   postgres and empty `data/postgres`) before running it again.
6. Start: `docker compose up -d --no-build web mcp scanner github notifier`. mcp, scanner, github and notifier wait for web to be healthy
   (it migrates first). If web is not healthy within its `start_period` (120 s) and 3 more checks — a long
   migration —, `up` exits `dependency failed to start` and leaves those four Created, not started (a restart policy
   never starts a container that never ran): once `/up` answers, run the same `up` again.
7. Check: `/up` 200; the board shows the cards; MCP `tools/list`; a new card gets the next id;
   `docker compose logs --since 5m web mcp scanner github notifier | grep -i error` empty.
8. Rollback: `.env` `DATABASE_ADAPTER=sqlite` (and `COMPOSE_PROFILES=` empty), `docker compose up -d --no-build web
   mcp scanner github notifier`: the services open the untouched SQLite file. Writes made on PostgreSQL in between
   are not in it.

## Dictation (the card dialog's mic)

An open card's comment box has a mic button; **⌥R / Alt+R** held anywhere in the card records (push-to-talk: release it to stop) (each viewer picks
another key, or none, on **Settings → Shortcuts**: kept in that browser; combos the browser, the OS or the editor owns are
refused with the reason; a combo another app on the computer takes never reaches the browser — the recorder shows
the modifiers but never the key, and says so). You speak, the words
appear in the comment while you talk (2.5 s windows, the words two passes agree on are kept, the rest shown as it
settles), and Save posts it like a typed comment. The text is read-only while it records; a failed window shows the
server's reason under the box and is retried. Off by default (`dictation: none`: no mic anywhere).

```
browser (16 kHz mono WAV windows) ── POST /api/dictation (session + CSRF) ──▶ web ── multipart ──▶ speech server
                                                                                     DICTATION_URL /v1/audio/transcriptions
```

The speech server is any **OpenAI-compatible** `POST /v1/audio/transcriptions` that answers `verbose_json` with word
timings (`words`, or `segments[].words`; both `timestamp_granularities[]=word` and `timestamp_granularities=word` are
sent): OpenAI itself, a faster-whisper server, a vLLM fleet's load balancer serving a whisper model. Its URL and token
stay in the web container (`.env`), never in the browser.

| where | key | value |
|---|---|---|
| `config/busyyaks.yml` | `dictation` | `none`, or `{model: <the server's model id>, timeout_seconds: 1..300, max_seconds: 30..600}` (30 = the mic's longest window) |
| `.env` (web only) | `DICTATION_URL` | the server's base or full endpoint, http(s); empty with `none` |
| `.env` (web only) | `DICTATION_TOKEN` | its bearer; empty = none sent; empty with `none` |
| `.env` (optional) | `COMPOSE_FILE`, `DICTATION_NETWORK` | a server reachable only on a docker network (below) |

The web boot (`config/puma.rb`) refuses a config and env that disagree. `/api/dictation`: 404 off · 400 not that WAV ·
413 longer than `max_seconds` · 502 the server unreachable, timed out or erroring (its reason) · 503 misconfigured.

**No speech server yet?** Run one on the same host (CPU; a GPU image `0.8.3-cuda` exists), then download a model into it:

```sh
docker run -d --name speaches --restart unless-stopped -p 127.0.0.1:8000:8000 \
  -v speaches-cache:/home/ubuntu/.cache/huggingface ghcr.io/speaches-ai/speaches:0.8.3-cpu
curl -X POST http://127.0.0.1:8000/v1/models/Systran/faster-whisper-small     # once: fetches the model
```

The web container cannot reach the host's `127.0.0.1`; publish the server where the container sees it, or put both on
one docker network:

**A server on a docker network** (e.g. a fleet load balancer that serves inference only to containers on its client
network, never on a public address): `docker-compose.dictation-network.yml` moves the web service from the default
bridge onto that existing network, where the server answers by its container name. In `.env`:

```sh
COMPOSE_FILE=docker-compose.yml:docker-compose.dictation-network.yml
DICTATION_NETWORK=speech-clients              # docker network ls; must exist, not --internal
DICTATION_URL=http://speaches:8000            # the server's container name on that network
DICTATION_TOKEN=
```

and `dictation: {model: Systran/faster-whisper-small, timeout_seconds: 30, max_seconds: 120}`; then
`docker compose up -d --no-build web`. Check: open a card, press the mic (the browser asks for the microphone once:
https or localhost only), speak, stop — the words are in the box.

## Terminals (an agent's live screen)

**Open terminal** in the Agents sidebar and a card's **Terminals** section show an agent session's tmux pane
in the browser, live, at the pane's own size (the browser never resizes the agent's window). It opens **read-only**;
**Take control** lets your keys reach the agent until **Release control**. This reverses the launcher's earlier rule
that only a verdict about the screen leaves the host: the screen and your keys now cross the web.

| | |
|---|---|
| config | `config/busyyaks.yml` `terminal: { public_host: allow \| deny, max_open: 1..64 }`, required, no default. `public_host: deny` refuses a terminal opened through `PUBLIC_HOST` (modes 2 and 3); `127.0.0.1` / `localhost` on `WEB_HOST_PORT` (an `ssh -L` forward included) always may. `max_open` = terminals open at once in the web process (each holds one thread); one more → 503 |
| who | a signed-in session only (`Auth.identify`; with `provider: none` that is anyone who reaches the port, as for the rest of the dashboard); never the MCP bearer (the MCP server has no such route) |
| page | the upgrade must carry an `Origin` equal to its Host's own origin (no Origin, or another site's → 403): a page elsewhere cannot open one |
| which session | only a session with an open registration on a board (busyyaks launched it, or it ran `kanban_register`) → else 404; the launcher then attaches only a running session with an agent (claude, or a `launch.commands` command) in its pane → else 404 / 403 |
| keys | dropped unless in control, in the page, in the web relay and in the launcher (each refuses on its own). The viewer's tmux client is `read-only` for its whole life and never takes a key: in control a key is `tmux copy-mode -q ; send-keys -H <hex bytes>` into the session's pane in one tmux command — any mode of the pane (copy mode, choose-tree: their key tables take even literal keys) cancelled first, then each byte as typed with no key table (hex, so no argument tmux reads as its own), so the tmux prefix, `:` / `run-shell`, mode bindings, new windows and session switches are out of reach. Taking control re-checks the session runs with an agent in its pane; the client showing another session (the session ended, tmux moved it) ends the terminal |
| audit | each open, take and release → a `terminal` event by you on every card the session works on (owns, or is assigned to its agent name; a session on no card: the launcher log line only), and a launcher log line (`journalctl --user -u busyyaks-launcher`) |
| proxy | mode 2 / 3 with `public_host: allow`: the nginx template's `location = /api/terminal` passes the WebSocket upgrade (`bin/render-deploy` again after an update) |
| wire | the launcher's `attach` op on its socket: one JSON line `{ok, session, cols, rows, screen}`, then JSON lines both ways (`lib/busyyaks/terminal.rb`); the web relays it as WebSocket text messages |

## GitHub webhook (wakes the PR / CI polls)

Card #472: the card links' PR flags (`gh_pr_states`) and the approval gates' CI (`gh_pr_checks`) are polled by the
`github` service every `github_ci_interval_seconds`. A GitHub webhook can wake that poll: a `pull_request`, `status`,
`check_run` or `check_suite` delivery marks the rows it names dirty, and the service reads just those within
`wake_seconds`. **Polling stays the only source of a state**: a delivery is never stored or believed, it only names
rows to read again, and it never creates one (only PRs someone already asked for within the poll window).

| | |
|---|---|
| config | `config/busyyaks.yml` `github_hook`, required, no default: `none` (off: no route, a POST is 404) or `{max_body_bytes: 1024..1048576, wake_seconds: 1..60}` — GitHub caps deliveries at 25 MB, but a `pull_request` payload (one PR, its body ≤ 65,536 characters) or a status / check payload is tens of KB; a bigger one → 413, which costs only the poll interval's latency |
| secret | `.env` `GITHUB_WEBHOOK_SECRET`, web service only: empty with `none`; when on ≥ 32 characters, no whitespace (`openssl rand -hex 32`). The web boot refuses on without a secret, and a secret with `none` |
| endpoint | `POST /api/github/hook` (`lib/busyyaks/github_hook.rb`). No session or CSRF token: the HMAC-SHA256 `X-Hub-Signature-256` over the raw body, compared in constant time, is its only authentication. Behind `HostGuard` like every route (GitHub sends the `PUBLIC_HOST` Host and no Origin). Refusals: body over `max_body_bytes` 413 · signature missing or wrong 401 · no `X-GitHub-Event` 400 · not `application/json` 415 · malformed payload 400. `ping` 200; any other event 204 (ignored) |
| marks | `pull_request` → that PR's `pr:N` state row and its `pr:N` / `merge:N` check rows; `status` / `check_run` / `check_suite` → the check rows whose head is that commit, the PRs the payload names, and the repo's `merge:*` rows. Repo matched case-insensitively. Column `dirty` (a counter, migration `20261208472000`): a poll clears only the mark it read |
| proxy | modes 2 / 3 only (GitHub must reach `https://<PUBLIC_HOST>`). The nginx template's `location = /api/github/hook` takes its body cap from the same `github_hook.max_body_bytes` (`bin/render-deploy` reads config/busyyaks.yml: one number, never a second one in nginx — its default 1m would 413 first) and passes `Host` unchanged; with `none` it answers 404 at the proxy. Re-render and reload nginx after changing `github_hook`. Localhost-only (mode 1): leave it `none` |

**Upgrading an existing deployment** (one with no `github_hook` yet): add both lines, even to keep the hook off —

```
# config/busyyaks.yml
github_hook: none
# .env
GITHUB_WEBHOOK_SECRET=
```

Without the config key every service stops at boot (`missing keys: github_hook`); without the env key compose refuses
to start the stack (`GITHUB_WEBHOOK_SECRET` unset) and the web boot says `GITHUB_WEBHOOK_SECRET not in the web
service's env`.

**Turning it on** (the operator, once per repo whose PRs the board tracks):

1. `.env`: `GITHUB_WEBHOOK_SECRET=$(openssl rand -hex 32)`; `config/busyyaks.yml`: `github_hook: { max_body_bytes: 1048576, wake_seconds: 5 }`.
2. `docker compose up -d --no-build web github` (the web boot checks the pair; the github service reads `wake_seconds`);
   modes 2 / 3: `bin/render-deploy nginx`, install it on the proxy host and reload nginx (the hook's location changes from
   404 to the proxied route with the body cap).
3. GitHub → the repo → Settings → Webhooks → Add webhook: Payload URL `https://<PUBLIC_HOST>/api/github/hook`, Content
   type `application/json`, Secret = the same value, SSL verification on, events "Let me select": Pull requests,
   Statuses, Check runs, Check suites. Or `gh api repos/<owner>/<repo>/hooks -f name=web -F active=true
   -f 'events[]=pull_request' -f 'events[]=status' -f 'events[]=check_run' -f 'events[]=check_suite'
   -f config[url]=https://<PUBLIC_HOST>/api/github/hook -f config[content_type]=json -f config[secret]=<secret>`.
4. **Live check**: GitHub → the webhook → Recent Deliveries: the `ping` delivery (sent on creation; or **Redeliver** it)
   answered **200** with body `{"ok":"pong"}`. A 401 = the secrets differ; 404 = `github_hook: none` at the app (JSON
   body) or at the proxy (nginx's page: re-render); 421 = the Host is not `PUBLIC_HOST`; 413 = over `max_body_bytes`.
   Then push to a PR a card shows: its delivery answers 200 `{"event":"pull_request","marked":N}` and
   `docker compose logs github` prints `hook woke the pollers polled=N` within `wake_seconds`.

Off again: `github_hook: none`, empty the secret, restart web + github, delete the webhook on GitHub.

## CI checks (the approval gate)

Card #470: the `github` service reads a card's assigned PR checks for the approval gate (`lib/busyyaks/ci_checks.rb`,
table `gh_pr_checks`); `config/busyyaks.yml` `ci` (required, no default) says what counts.

| | |
|---|---|
| config | `ci: { max_pending_minutes: 1..1440, required: { <owner/name>: [<context>, …] } }` — list every repo whose PRs are assigned to cards (the private local repo, the public one, the engine's): a repo not listed → its rows answer "no required CI contexts for <repo>" and the gate refuses with it. An edit needs a restart of `github` (it reads the file at start) |
| coverage | at boot `ci` must be present and well-formed (else every service stops). A repo missing from `ci.required` stops nothing: the local or public repo of an ENROLLED project (`git mirror-init`'s guard remotes, as the scanner read them) that is not listed is shown on `/github` ("CI contexts not configured for <repo>") and in the `github` log at start; a card whose PR is on any unlisted repo has its handoff / Approve refused with "no required CI contexts for <repo>: config/busyyaks.yml ci.required does not list it". Every other project's PRs are still polled |
| required vs informational | only the listed contexts (a commit status `context`, e.g. `jenkins/ci`, or a check run `name`) gate: all finished and none failed → green. Another check is informational: its failure is named in the refusal / gate line, never a refusal. A required context that has not reported → "required … not reported", not green |
| stuck | a required check pending longer than `max_pending_minutes` (since its pending status was posted / its run started) → state `stuck`: the gate holds it and pings the owner once per stuck build ("CI stuck — jenkins/ci pending since …") |
| pages | every page of the commit's statuses and check runs is read (GitHub's `total_count`); a list GitHub counts but does not hand over whole is refused, never taken for green |
| ci_url | a handoff's `ci_url` must be a build URL (`target_url` / `details_url`) of a required check on the head it hands over; checked at the handoff only (an older build is refused there); the Approve and the watch passes take any green build of the required checks on the head, so a rebuild after the handoff never parks the card |
| errors | one PR whose read fails (GitHub's error, or any other) keeps its error on its row; the rest of the batch is still read |
| queued runs | a check run has no `created_at`, and a queued one may have no `started_at`: its pending time then counts from the later of its check suite's `created_at` and the first poll that saw that run (by id) pending (`gh_pages` `ci:seen:…`: a re-run reuses the old suite, so it is never stuck at once); a finished required check with no completion time is refused on its row |

## Reading the scanned repos

Every service reads a repo under `PROJECTS_ROOT` only through `bin/git-read` (`lib/busyyaks/git_read.rb`): one
child process per read, libgit2 through the rugged gem, built in the image against the libgit2 version the
`Dockerfile` pins (no SSH / HTTPS transport, the system zlib, POSIX regex; CI's `audit` stage fails when libgit2 ships a
newer security release). No long-lived process runs the git CLI on a scanned repo or loads libgit2 itself.

| a crafted repo | what happens |
|---|---|
| its config names a program (filter driver, textconv, `diff.external`, fsmonitor, pager, hooks) | libgit2 runs none of them |
| `commondir`, alternates, a `gitdir:` file or a symlinked git file pointing out of the projects root; `core.worktree`; sparse checkout; an `include` / `includeIf` in its config; a FIFO where a git file should be | refused before libgit2 opens it: an error on that repo |
| anything that still hangs or grows (a FIFO named by `core.excludesFile`, a huge diff) | the child is killed at `GIT_READ_TIMEOUT_SECONDS` / `GIT_READ_CPU_SECONDS` / `GIT_READ_MEMORY_BYTES`; a file over `GIT_READ_MAX_BLOB_BYTES` is never loaded (binary, said so) |

The child starts with an empty environment (no token or secret of its service: a repo's config can make libgit2 read
any file the child can, `/proc/self/environ` included) and cwd `/`. A failed read keeps the repo's last good row with
the reason (`projects.git_error`) and names the repo in the scan's error on the dashboard.

**Remaining risk.** The containment checks run before libgit2 opens the repo and again after it; a process on the
host that can write under `PROJECTS_ROOT` can still swap a symlink between them. What it reaches then is what the
child can read with no secrets in its environment, inside its limits. The host side still runs the git CLI in two
places: the launcher's `create` (`git init` / `git clone` of a URL the operator gives) and the daily report's runner
(its own git tool).

## Rollback

Remove the nginx symlink and reload nginx, or remove the `[busyyaks]` block from `frpc.ini`. The app is still served
on `127.0.0.1` (mode 1).
