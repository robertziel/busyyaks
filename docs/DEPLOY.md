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
6. Start: `docker compose up -d --no-build web mcp scanner github notifier`.
7. Check: `/up` 200; the board shows the cards; MCP `tools/list`; a new card gets the next id;
   `docker compose logs --since 5m web mcp scanner github notifier | grep -i error` empty.
8. Rollback: `.env` `DATABASE_ADAPTER=sqlite` (and `COMPOSE_PROFILES=` empty), `docker compose up -d --no-build web
   mcp scanner github notifier`: the services open the untouched SQLite file. Writes made on PostgreSQL in between
   are not in it.

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
