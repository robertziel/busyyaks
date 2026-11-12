#!/usr/bin/env bash
# Installs the daily-report tick as a systemd --user timer, from the current Settings → Daily report revision
# (schedule, run_timeout, runner.command), read through the busyyaks MCP tool daily_report_config (the MCP
# service must be up). The service PATH holds the runner's command, ruby (bin/env), jq, curl, flock and timeout. Records
# what it installed in data/daily-timer.json: bin/daily-report re-runs this script whenever a saved revision differs
# from it, so a page edit of those three applies at the next tick.
set -euo pipefail
dir=$(cd "$(dirname "$0")/.." && pwd)
for c in ruby jq curl flock timeout; do command -v "$c" >/dev/null || { echo "$c not on PATH" >&2; exit 1; }; done
# .env through bin/env (the one .env reader: a malformed .env or a missing key stops here, naming it)
# the report's scoped bearer (MCP_REPORT_TOKEN reaches daily_report_config), never the full MCP bearer
vars=$("$dir/bin/env" MCP_HOST MCP_HOST_PORT MCP_REPORT_TOKEN)
eval "$vars"
body='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"daily_report_config","arguments":{}}}'
# the bearer as a header file (printf is a builtin): never in curl's argv, which /proc/*/cmdline shows
out=$(curl -sfS -m 30 -X POST "http://$MCP_HOST:$MCP_HOST_PORT/mcp" -H @<(printf 'Authorization: Bearer %s\n' "$MCP_REPORT_TOKEN") \
  -H 'Content-Type: application/json' -d "$body")
jq -e '.result.isError == false' <<<"$out" >/dev/null || { jq -r '.result.content[0].text // .' <<<"$out" >&2; exit 1; }
res=$(jq -r '.result.content[0].text' <<<"$out")
[ "$(jq -r .configured <<<"$res")" = true ] || { echo "daily report not configured: $(jq -r .reason <<<"$res")" >&2; exit 1; }
cfg=$(jq -c .config <<<"$res")
schedule=$(jq -er .schedule <<<"$cfg"); run_timeout=$(jq -er .run_timeout <<<"$cfg"); cmd=$(jq -er .runner.command <<<"$cfg")
runner_type=$(jq -er .runner.type <<<"$cfg")
[[ "$runner_type" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "runner.type (Settings → Daily report) is not a runner name (^[a-z][a-z0-9_-]*$)" >&2; exit 1; }
{ [ -f "$dir/bin/daily-report-runners/$runner_type" ] && [ -x "$dir/bin/daily-report-runners/$runner_type" ]; } \
  || { echo "no runner script for runner.type $runner_type (Settings → Daily report)" >&2; exit 1; }
command -v "$cmd" >/dev/null || { echo "runner.command $cmd (config/busyyaks.yml daily_report_runners) not on PATH" >&2; exit 1; }
systemd-analyze calendar -- "$schedule" >/dev/null
cmd_dir=$(dirname "$(command -v "$cmd")"); ruby_dir=$(dirname "$(command -v ruby)")
# systemd TimeoutStartSec: the run timeout plus 10 min for probes, the FAILED post and timeout(1)'s kill grace.
run_us=$(systemd-analyze timespan -- "$run_timeout" | awk '$1 == "μs:" {print $2}')
[ -n "$run_us" ] || { echo "run_timeout '$run_timeout' (Settings → Daily report) is not a timespan" >&2; exit 1; }
timeout_sec=$(( run_us / 1000000 + 600 ))
dest=~/.config/systemd/user
mkdir -p "$dest"
# a value in a sed replacement: its \, & and the # delimiter escaped (a checkout path may hold any of them)
sed_value() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
sed -e "s#__DIR__#$(sed_value "$dir")#g" -e "s#__PATH__#$(sed_value "$cmd_dir:$ruby_dir:/usr/local/bin:/usr/bin:/bin")#" \
  -e "s#__TIMEOUT__#${timeout_sec}s#" \
  "$dir/deploy/busyyaks-daily.service" >"$dest/busyyaks-daily.service"
sed -e "s#__ON_CALENDAR__#$(sed_value "$schedule")#" "$dir/deploy/busyyaks-daily.timer" >"$dest/busyyaks-daily.timer"
systemctl --user daemon-reload
systemctl --user enable busyyaks-daily.timer
systemctl --user restart busyyaks-daily.timer
mkdir -p "$dir/data"
jq -cS '{schedule, run_timeout, command: .runner.command}' <<<"$cfg" >"$dir/data/daily-timer.json"
systemctl --user list-timers busyyaks-daily.timer --no-pager
