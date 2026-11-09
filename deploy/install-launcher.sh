#!/usr/bin/env bash
# Installs bin/launcher as a systemd --user service.
set -euo pipefail
dir=$(cd "$(dirname "$0")/.." && pwd)
# Linux with a systemd user manager; each tool the launcher runs, by name
[ "$(uname -s)" = Linux ] || { echo "bin/launcher runs on Linux only (it reads /proc); this is $(uname -s)" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemctl not on PATH: the launcher is a systemd --user unit" >&2; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 \
  || { echo "no systemd user manager for $(id -un) (systemctl --user fails): log in through a session, or loginctl enable-linger" >&2; exit 1; }
for c in ruby git tmux claude; do
  command -v "$c" >/dev/null || { echo "$c not on PATH: bin/launcher needs ruby (3.x), git, tmux and the claude CLI" >&2; exit 1; }
done
[ -f "$dir/.env" ] || { echo "$dir/.env missing: cp .env.example .env and fill it (README Quickstart)" >&2; exit 1; }
[ -f "$dir/config/busyyaks.yml" ] || { echo "$dir/config/busyyaks.yml missing: cp config/busyyaks.example.yml" >&2; exit 1; }
[ -f "$dir/config/kanban.yml" ] || { echo "$dir/config/kanban.yml missing: cp config/kanban.example.yml" >&2; exit 1; }
# the containers run as HOST_UID:HOST_GID and talk to this user's socket in LAUNCHER_RUN_DIR (mode 0600, the dir 0700;
# mounted only into web, mcp and notifier; outside PROJECTS_ROOT and this checkout, which containers mount too)
# (bin/env: the one .env reader — a malformed .env stops here, naming the line)
vars=$("$dir/bin/env" HOST_UID HOST_GID LAUNCHER_RUN_DIR PROJECTS_ROOT)
eval "$vars"
[ "$HOST_UID:$HOST_GID" = "$(id -u):$(id -g)" ] \
  || { echo ".env HOST_UID:HOST_GID is '$HOST_UID:$HOST_GID', this user is $(id -u):$(id -g): the containers could not reach the launcher socket" >&2; exit 1; }
# the launcher's own check (LauncherRules.run_dir!, the one definition): created 0700, this uid's, outside both
LAUNCHER_RUN_DIR="$LAUNCHER_RUN_DIR" PROJECTS_ROOT="$PROJECTS_ROOT" CHECKOUT="$dir" \
  ruby -r "$dir/lib/busyyaks/launcher_rules" -e '
    begin
      Busyyaks::LauncherRules.run_dir!(ENV.fetch("LAUNCHER_RUN_DIR"), projects_root: ENV.fetch("PROJECTS_ROOT"),
                                       checkout: ENV.fetch("CHECKOUT"), uid: Process.uid)
    rescue Busyyaks::LauncherRules::Invalid => e
      abort ".env #{e.message}"
    end' || exit 1
ruby=$(command -v ruby); tmux=$(command -v tmux); claude=$(command -v claude)
path="$(dirname "$claude"):$(dirname "$tmux"):$(dirname "$ruby"):/usr/local/bin:/usr/bin:/bin"
dest=~/.config/systemd/user; mkdir -p "$dest"
# a value in a sed replacement: its \, & and the # delimiter escaped (a checkout path may hold any of them)
sed_value() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
sed -e "s#__DIR__#$(sed_value "$dir")#g" -e "s#__RUBY__#$(sed_value "$ruby")#" -e "s#__PATH__#$(sed_value "$path")#" \
  "$dir/deploy/busyyaks-launcher.service" >"$dest/busyyaks-launcher.service"
systemctl --user daemon-reload
systemctl --user enable --now busyyaks-launcher.service
systemctl --user restart busyyaks-launcher.service
sleep 1
# the unit must be running now; its full status is printed only when it is not (no pipe to `head`: under pipefail
# the SIGPIPE it sends systemctl made a successful install exit 141)
if ! systemctl --user is-active --quiet busyyaks-launcher.service; then
  systemctl --user --no-pager status busyyaks-launcher.service >&2 || echo "(systemctl status exited $?)" >&2
  echo "busyyaks-launcher.service is not active after the restart: see the status above and journalctl --user -u busyyaks-launcher" >&2
  exit 1
fi
echo "busyyaks-launcher.service: active"
