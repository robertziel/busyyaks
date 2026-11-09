# The daily report

How it runs is configuration: `daily_report` in `config/busyyaks.yml` (optional — absent = no daily report; every key
documented in [`config/busyyaks.example.yml`](../config/busyyaks.example.yml)): the schedule, the cutoff, the
timeouts, the OpenAI-compatible gateway, the models and the **runner** — the agent CLI that writes the report. Runner
types live in `bin/daily-report-runners/`; today: `hermes` ([Hermes](https://github.com/NousResearch/hermes-agent):
`command`, `home`, `max_children`).

`bin/daily-report` runs on the host from a systemd user timer (`deploy/install-daily-timer.sh` installs it at
`daily_report.schedule`). It reads the validated config through the MCP tool `daily_report_config`. Each tick:

1. If today's report exists, exit.
2. Probe `daily_report.gateway`: both configured models listed (or the one served model for `served`), a 1-token
   completion, enough context. Down → log and exit; after `daily_report.cutoff` → post one `NOT RUN` report.
3. Up → start the runner. `hermes`: the busyyaks MCP server is its only tool source; there is no terminal, no process
   tool and no git on the host. Before it starts, the scan it would read is checked (`daily_facts` `last_scan`): none, a
   failed one, or a stale one — older than 3 × `SCAN_INTERVAL_SECONDS` + min(its duration, one interval), or more than
   60 s in the future, or a row with no start time / a negative duration. Before `daily_report.cutoff` that is a log
   line and exit 0 (the next tick retries); from the cutoff on, or with `--force`, one `FAILED` report saying why. No
   run either way. The lead model reads the last scan through `daily_facts` (it never asks for a scan), spawns one child
   per active repo with that repo's `daily_facts` entry (subjects, each commit's paths in `churn.commits`, the
   uncommitted `dirty_paths`), checks the draft with `check_report`, and posts it. The children have the busyyaks MCP only.

Reports are stored in the busyyaks database (`post_report` → `reports`) and shown on `/reports`. The model writes the
prose; every figure comes from `daily_facts`, and `check_report` rejects a draft that names repos, people or events the
server does not know. A failure posts a `FAILED` report; `bin/daily-report --force` reruns a day. The layout is the
`report_components` tool's "Suggested daily layout".
