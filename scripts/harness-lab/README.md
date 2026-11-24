# Harness lab

The real Claude Code, Hermes and Codex CLIs, pinned in `Dockerfile`, each in tmux against a scripted model + MCP server
([aimock](https://github.com/CopilotKit/aimock) 1.48.1, MIT, pinned by sha256; `lab_mock.mjs` is only the script of turns). No network at run time, no credentials, no tokens spent.

```sh
scripts/harness-lab/run <new output dir> [claude hermes hermes-interrupt codex]
```

| step (`contract`) | checks |
|---|---|
| `starts` · `answers` | the TUI comes up and answers a typed line |
| `mcp_tool` · `mcp_answered` | the model's call reaches the MCP server, the turn ends |
| `dialog_before_shell` · `shell_after_approve` · `shell_answered` | a shell command waits on a dialog, runs after Enter, the turn ends |
| `ping_kept_turn` | a line pasted mid-turn starts no new request while the turn runs |
| `ping_delivered_after` | that line reaches the model afterwards |
| `slow_answer_kept` · `slow_answer_on_screen` | the running turn's answer survives the paste |
| `mock_clean` | the mock raised no error and got no main turn without tools |

Every step must pass; a failure exits 1 and is named (`FAILED <harness>.<step>`). Each step's screen is kept in
`<output dir>/<harness>/`.

`hermes` runs the overlay bin/launcher gives a board session (`HERMES_MANAGED_DIR`: `busy_input_mode: queue`, the MCP server, its token in the file); `hermes-interrupt` is the same with Hermes's default mode.

Red today:

| steps | why | fixed by |
|---|---|---|
| `hermes-interrupt.ping_kept_turn` · `.slow_answer_kept` · `.slow_answer_on_screen` | a line typed mid-turn cuts the turn: Hermes's default, kept as the measured reason | never fixed here: busyyaks launches Hermes in queue mode |
| `codex.slow_answer_kept` · `.slow_answer_on_screen` | Codex 0.166.0 discards the in-flight answer when a line is typed mid-turn (without the paste the answer shows) | deliver pings to Codex some other way than a paste |

The CI stage is switched on once these are fixed.

## The board end to end

```sh
scripts/harness-lab/board-e2e <new output dir>
```

A real Hermes lead + worker against a throwaway stack built from this checkout, with the scripted model (`board_mock.mjs`), run by `board_e2e.rb`. Exit 0 only when every step passed; the first failure is named (`FAIL <step>: <why>`). `<output dir>` keeps `steps.log` + `screens/`.

| isolated | how |
|---|---|
| secrets, config | `bin/setup` in a private temp dir; no `.env`, no `~/.hermes` is read |
| stack | its own compose project + image, removed on exit; the live stack, its image and its tmux server are never touched |
| network | none at run time: every service shares one `--network none` namespace |

| covered | steps |
|---|---|
| refusals, real launches | no `mcp_servers` → 422 naming the file + line, session + stage gone · a Hermes started by hand → `unsupported`, nothing typed |
| flow | lead spawns worker · comment · mid-turn ping queued, turn kept · ask · answer · handoff |
| dialogs from the card | Deny (key 4): command never runs · Allow once (key 1): command runs · a ping held through the open panel |
| no ping lost or doubled | each operator comment's marker reaches the model exactly once |
| what a ping leaves in the input, through the real `bin/collector` + the launcher's `notify` (`board_tmux_shim` holds the paste until the panel is open) | a dialog between paste and Enter: no Enter into it · a collector restart, then the retry: one copy · a different ping meanwhile: refused, never glued · a paste that renders late: entered once, or past the window failed for good and never pasted again · a person's half-typed draft: never sent, overwritten or quoted |
| exact counts | every ping is counted `== 1` at the model after a settle delay |
| secrets | the token in no argv, launcher / collector / mock / service log, or file under Hermes's home; overlay 0700 / 0600; the user's `config.yaml` byte-identical |

Not covered: a real model; Hermes's installer launcher (the image is a pip install).
