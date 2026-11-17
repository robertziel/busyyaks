#!/usr/bin/env bash
# Installs bin/collector (busyyaks's agent-session collector, card #479) as a systemd --user service, at the paths
# config/busyyaks.yml agents.collector names. Then restart the launcher (deploy/install-launcher.sh): it reads the
# collector's paths at its start.
set -euo pipefail
dir=$(cd "$(dirname "$0")/.." && pwd)
[ "$(uname -s)" = Linux ] || { echo "bin/collector runs on Linux only (it reads /proc); this is $(uname -s)" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemctl not on PATH: the collector is a systemd --user unit" >&2; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 \
  || { echo "no systemd user manager for $(id -un) (systemctl --user fails): log in through a session, or loginctl enable-linger" >&2; exit 1; }
for c in ruby tmux; do
  command -v "$c" >/dev/null || { echo "$c not on PATH: bin/collector needs ruby (3.x) and tmux" >&2; exit 1; }
done
[ -f "$dir/.env" ] || { echo "$dir/.env missing: cp .env.example .env and fill it (README Quickstart)" >&2; exit 1; }
[ -f "$dir/config/busyyaks.yml" ] || { echo "$dir/config/busyyaks.yml missing: cp config/busyyaks.example.yml" >&2; exit 1; }
# the collector's own start checks (agents.collector set, its dir private and outside every container mount): one definition
ruby "$dir/bin/collector" --check || exit 1
snapshot=$(ruby -ryaml -e 'puts YAML.safe_load_file(ARGV[0]).dig("agents", "collector", "snapshot")' "$dir/config/busyyaks.yml")
ruby=$(command -v ruby); tmux=$(command -v tmux)
path="$(dirname "$tmux"):$(dirname "$ruby"):/usr/local/bin:/usr/bin:/bin"
dest=~/.config/systemd/user; mkdir -p "$dest"
sed_value() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
sed -e "s#__DIR__#$(sed_value "$dir")#g" -e "s#__RUBY__#$(sed_value "$ruby")#" -e "s#__PATH__#$(sed_value "$path")#" \
  "$dir/deploy/busyyaks-collector.service" >"$dest/busyyaks-collector.service"
# the snapshot's mtime (ns) before this start: only a snapshot written AFTER it proves this collector runs
mtime() { if [ -f "$snapshot" ]; then date -r "$snapshot" +%s%N; else echo 0; fi; }
before=$(mtime)
systemctl --user daemon-reload
systemctl --user enable --now busyyaks-collector.service
systemctl --user restart busyyaks-collector.service
# active, and a snapshot written by this start (it writes one before it listens, then every interval)
fresh() { systemctl --user is-active --quiet busyyaks-collector.service && [ "$(mtime)" -gt "$before" ]; }
for _ in $(seq 1 20); do
  fresh && break
  sleep 0.5
done
if ! fresh; then
  systemctl --user --no-pager status busyyaks-collector.service >&2 || echo "(systemctl status exited $?)" >&2
  echo "busyyaks-collector.service is not active with a snapshot written since this start at $snapshot: see the status above and journalctl --user -u busyyaks-collector" >&2
  exit 1
fi
echo "busyyaks-collector.service: active · $snapshot"
echo "next: deploy/install-launcher.sh (the launcher reads the collector at its start)"
