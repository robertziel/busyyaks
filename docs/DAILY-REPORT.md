How it runs is data: the current revision of **Settings → Daily report** (the header cog menu; table
`daily_report_settings`, one row per save, every earlier one kept) — the schedule, the cutoff, the timeouts,
the OpenAI-compatible gateway, the models and the **runner** — the agent CLI that writes the report. Runner types live
in `bin/daily-report-runners/`; today: `hermes` ([Hermes](https://github.com/NousResearch/hermes-agent): `command`,
`home`, `max_children`). What a runner may execute stays on the host: `config/busyyaks.yml` `daily_report_runners`
lists each allowed `{type, command, home}`; the page picks one (a save naming another is refused, and a revision whose
runner the host list dropped does not run).

| key | |
|---|---|
| `schedule` | systemd OnCalendar of the tick, local time; the first tick that finds the gateway up writes the day's report, later ticks exit |
| `cutoff` | HH:MM local: from then on, a tick that finds the gateway down posts ONE `NOT RUN` report |
| `probe_timeout` | seconds for each gateway probe request (GET /models, a 1-token completion) |
| `run_timeout` | wall-clock limit of one run (timeout(1) duration); hitting it posts the `FAILED` report |
| `gateway` | OpenAI-compatible base URL the runner talks to (ends in /v1) — its only provider, no fallback |
| `model` | the lead model, id exactly as GET /models lists it; `served` = the one model the gateway serves at that tick (0 or several → offline) |
| `agent_model` | the child model (one child per active repo), same rules |
| `context_length` | the lead model's context window in tokens (a served max_model_len below it → offline) |
| `runner` | `type` + that type's keys; `hermes`: `command` + `home` (from `daily_report_runners`), `max_children` (children at once) |

The allowlist is the source of `command` and `home`: a revision stores the entry it picked, so after an allowlist edit
(a moved `home`, a renamed `command`) the saved revision no longer matches — the page and every tick say it does not
run, naming the entry — until the runner is picked again and saved. Never repaired silently.

Not configured — no revision saved, or the current one does not run — posts ONE `Daily report <day> NOT CONFIGURED`
report saying why (exit 2); it does not count as the day's report, so settings saved later that day run at the next
tick. From a shell: `docker compose exec -T web bin/daily-report-settings show | import < file` (import takes the old
`config/busyyaks.yml` block as is).

`bin/daily-report` runs on the host from a systemd user timer (`deploy/install-daily-timer.sh` installs it at the
`schedule`, recording what it installed in `data/daily-timer.json`). It reads the validated settings through the MCP
tool `daily_report_config`; when the revision's `schedule`, `run_timeout` or `runner.command` differ from that record,
the tick re-runs the installer first (refused → `NOT CONFIGURED`, saying why). Each tick:

1. If today's report exists, exit.
2. Probe the `gateway`: both configured models listed (or the one served model for `served`), a 1-token
   completion, enough context. Down → log and exit; after the `cutoff` → post one `NOT RUN` report.
3. Up → start the runner. `hermes`: the busyyaks MCP server is its only tool source; there is no terminal, no process
   tool and no git on the host. Before it starts, the scan it would read is checked (`daily_facts` `last_scan`): none, a
   failed one, or a stale one — older than 3 × `SCAN_INTERVAL_SECONDS` + min(its duration, one interval), or more than
   60 s in the future, or a row with no start time / a negative duration. Before the `cutoff` that is a log
   line and exit 0 (the next tick retries); from the cutoff on, or with `--force`, one `FAILED` report saying why. No
   run either way. The lead model reads the last scan through `daily_facts` (it never asks for a scan), spawns one child
   per active repo with that repo's `daily_facts` entry (subjects, each commit's paths in `churn.commits`, the
   uncommitted `dirty_paths`), checks the draft with `check_report`, and posts it. The children have the busyyaks MCP only.

Reports are stored in the busyyaks database (`post_report` → `reports`) and shown on `/reports`. The model writes the
prose; every figure comes from `daily_facts`, and `check_report` rejects a draft that names repos, people or events the
server does not know. A failure posts a `FAILED` report; `bin/daily-report --force` reruns a day. The layout is the
`report_components` tool's "Suggested daily layout".

## Moving off config/busyyaks.yml

A deployment whose `config/busyyaks.yml` still has the `daily_report` block does not boot until it is
moved — `Config.load` refuses the key, and the import reads the allowlist from the same file, so the order is fixed:

1. Copy the `daily_report:` block into a file (e.g. `daily_report.yml`, outside the repo).
2. In `config/busyyaks.yml`, replace the block by `daily_report_runners: [{type: hermes, command: <its runner.command>,
   home: <its runner.home>}]`.
3. Deploy, then `docker compose exec -T web bin/daily-report-settings import < daily_report.yml` (the file as is:
   the `daily_report:` key or the bare mapping).
4. `deploy/install-daily-timer.sh` (or wait for a tick: it re-installs the units from the revision).
