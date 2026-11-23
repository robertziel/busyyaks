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

`hermes` runs `busy_input_mode: queue`, the mode a board session needs; `hermes-interrupt` runs Hermes's default.

Red today:

| steps | why | fixed by |
|---|---|---|
| `hermes-interrupt.ping_kept_turn` · `.slow_answer_kept` · `.slow_answer_on_screen` | a line typed mid-turn cuts the turn | run Hermes in queue mode |
| `codex.slow_answer_kept` · `.slow_answer_on_screen` | Codex 0.166.0 discards the in-flight answer when a line is typed mid-turn (without the paste the answer shows) | deliver pings to Codex some other way than a paste |

The CI stage is switched on once these are fixed.
