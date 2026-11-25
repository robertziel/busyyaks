# Session isolation — the operator's use cases and how each was tested

The operator's requirements (2026-11-24) for which sessions are busyyaks's, each with the automated tests that pin it
and the live check run on a local deployment. Kept as the starting list for an end-to-end suite.

Live checks run on a test project `yaks_testbed` (created by the launcher's `create` op, so it is trusted), every
real session on a launcher pointed at a local model gateway (no Anthropic tokens). Browser checks: Chromium
(puppeteer in Docker) against the https `PUBLIC_HOST` — over plain http the `Secure` session cookie drops the CSRF
token and every mutation is refused — with the trackers blocked at the network layer and `bin/qa-cookie` for sign-in.

Safety rules for anyone running them: never `tmux kill-server`; a test tmux server only through
`env -u TMUX tmux -S <its own socket>`; never stop a session, PID or container the test did not start; never rebuild or
restart the live stack from a worktree.

| # | use case (the operator's words) | automated tests | live check | expected |
|---|---|---|---|---|
| U1 | "A session started from the terminal, not from busyyaks, should have no idea about any rules we've got related to busyyaks" — any project, any directory, any harness | `mcp_test` `test_a_terminal_session_sees_no_board_tool_and_no_board_text`; `project_agent_rules_test` (nothing auto-loaded holds a rule); `collector_test` `test_a_session_started_from_the_terminal_is_never_read` | start `claude` / `hermes` by hand in another project; list its skills, MCP servers and tools; grep its loaded context for busyyaks | no busyyaks skill, no busyyaks MCP server, no `kanban_*` tool, no busyyaks text |
| U2 | Only sessions busyyaks starts (Launch, the lead's spawn) get the busyyaks skill and the board — every harness | `launcher_trust_test` `test_a_claude_launch_carries_its_staged_skills`, `test_a_claude_launch_carries_the_board_mcp_in_its_own_stage`, `test_an_agent_up_without_the_board_mcp_is_refused`; hermes overlay test; `mcp_test` `test_a_session_busyyaks_launched_has_the_board_tools` | web Launch of the lead and a Sub team on `yaks_testbed`; read the running claude's argv and stage | `--plugin-dir <stage>`, `--mcp-config <stage>/mcp.json` (0600, board token), `/busyyaks:session` ran |
| U3 | "Add naming to the busyyaks sessions … start with BY so we can easily identify and isolate them" | `launcher_rules_test` `test_only_a_by_prefixed_name_is_a_busyyaks_session`; migration test `test_existing_agent_settings_get_the_by_prefix_as_a_new_revision` | the launched sessions' tmux names | `by_yaks_testbed_teamlead`, `by_yaks_testbed_team` |
| U4 | busyyaks never stops, types into, attaches to, reads or lists a session it did not start ("it's not related at all") | `collector_test` `test_no_op_acts_on_a_session_busyyaks_did_not_start`, `test_a_by_named_session_busyyaks_did_not_launch_is_never_touched`, `test_a_record_of_another_process_is_no_proof`; `launcher_attach_test` `test_a_session_busyyaks_did_not_start_is_never_attached`; frontend `sessionLanes.test` "the project page shows only sessions busyyaks runs" | a hand-run tmux session in `yaks_testbed` next to the launched ones; project page screenshot; Stop all; the Agents sidebar | no chip, not in the sidebar, Stop refuses it, never typed into |
| U5 | "Only sessions started from busyyaks create leads, not a session started from the terminal" | engine `lead_first_test`; `mcp_kanban_test` `test_a_terminal_session_never_becomes_the_lead_only_busyyaks_launch_does` | `kanban_register type: lead` over the board MCP from a session that was not launched | refused: "a lead is started only by the operator's Launch" |
| U6 | Per project, per agent type markdown rules set in the web (Project → Settings), loaded only through the busyyaks skill; custom ones live in the project's `.busyyaks/` | `project_agent_rules_test` (save → `.busyyaks/skills/agents/<type>.md` via the writer; the staged `session` skill holds it; a rule over the launch budget is refused on save; conflict 409; writer down 503) | save a rule for `lead` on `yaks_testbed` in the web, launch the lead, read its staged `session/SKILL.md`; a hand-run session in the dir | the rule is in the launched session's stage only |
| U7 | Nothing busyyaks in any global harness setting | — (host state) | grep `~/.claude/CLAUDE.md`, `~/.claude.json` `mcpServers`, `~/.hermes/config.yaml`, `~/.codex` | no busyyaks entry (Hermes: see open items) |
| U8 | When a busyyaks session ends, what it left running in the background is cleaned up | `launcher_rules_test` `test_stale_scopes_are_the_busyyaks_scopes_of_ended_sessions` | a `busyyaks-by_*` scope with no tmux session, then the `sessions` op | the scope is stopped and its processes logged |
| U9 | A ping that arrives while a session is still starting is delivered later, never lost | `launcher_rules_test` `test_a_ping_during_the_start_is_retried_never_dropped` | — | retried |
| U10 | Updating an existing install keeps working | `cli_update_test`, `launcher_update_test` (`bin/setup secrets` step) | — | the new secret written before the backup |

## Automated coverage (no AI)

Every live check in the table above, re-proven with no model, AI session, live stack or host tmux server: the real `bin/launcher` /
`bin/collector` against stub tmux / claude / hermes / systemctl in a temp dir, Rack::Test on the web and the MCP, the
repo's own files read as data. New tests are **bold**.

| # | live check | test (file: name) |
|---|---|---|
| U1 | a hand-run session has no busyyaks skill | `no_global_skill_test`: `test_no_code_installs_a_skill_user_wide`, `test_the_skills_live_only_in_the_launch_layers` |
| U1 | … no busyyaks MCP server | **`no_global_skill_test`: `test_nothing_tells_a_user_or_a_script_to_register_busyyaks_with_a_harness_user_wide`** · **`setup_test`: `test_installing_writes_nothing_into_any_harness_settings_or_a_projects_auto_loaded_files`** |
| U1 | … no `kanban_*` tool | `mcp_test`: `test_a_terminal_session_sees_no_board_tool_and_no_board_text` · **`mcp_test`: `test_the_board_token_lists_the_terminal_tokens_tools_and_every_board_tool`** |
| U1 | … no busyyaks text in what it loads | **`no_global_skill_test`: `test_the_board_workflow_lives_only_in_the_skills_never_in_a_file_a_cli_loads_by_itself`** · **`no_global_skill_test`: `test_no_installer_writes_a_harness_config_or_a_file_a_cli_loads_by_itself`** · `project_agent_rules_test` + `launcher_trust_test`: `test_a_session_started_from_the_terminal_in_the_projects_directory_gets_none_of_the_projects_agent_rules` |
| U2 | the web-launched lead's and Sub team's argv: `--plugin-dir <stage>`, `--mcp-config <stage>/mcp.json` (0600) before the prompt, prompt `/busyyaks:session …` | **`launcher_trust_test`: `test_a_session_busyyaks_starts_gets_its_skill_and_the_board_lead_and_sub_team_alike`** · `launcher_trust_test`: `test_a_claude_launch_carries_the_board_mcp_in_its_own_stage` · `launch_test`: `test_launch_registers_adopts_then_starts_and_reports_remote_control` (the web's side) |
| U2 | `MCP_BOARD_TOKEN` lists every tool (every `kanban_*`), `MCP_TOKEN` the same minus every `kanban_*` | **`mcp_test`: `test_the_board_token_lists_the_terminal_tokens_tools_and_every_board_tool`** |
| U3 | the launched sessions' names `by_<slug>_teamlead` / `by_<slug>_team` / `by_<slug>` | **`launch_test`: `test_every_session_the_web_launches_is_named_by`** |
| U3 | a name without `by_` never starts; Settings refuses one | **`launcher_trust_test`: `test_the_launcher_starts_no_session_whose_name_does_not_start_with_by`** · **`session_isolation_test`: `test_agent_settings_refuse_a_session_name_without_by_through_the_web_api`** (422, nothing written) |
| U3 | a new agent settings revision = the migration's `by_` rename | `migrations_test`: `test_existing_agent_settings_get_the_by_prefix_as_a_new_revision` |
| U4 | the hand-run session: no chip on the project page | **`session_isolation_test`: `test_the_project_page_lists_no_session_started_from_the_terminal`** (web → real launcher) · frontend `sessionLanes.test`: "the project page shows only sessions busyyaks runs" |
| U4 | … not in the Agents sidebar | **`session_isolation_test`: `test_a_session_started_from_the_terminal_is_not_in_the_agents_sidebar`** (web → real launcher + collector) |
| U4 | … web Stop refuses it, it keeps running | **`session_isolation_test`: `test_stop_answers_not_started_by_busyyaks_for_a_session_started_from_the_terminal_and_it_keeps_running`** · `collector_test`: `test_no_op_acts_on_a_session_busyyaks_did_not_start` |
| U4 | … never typed into, read or attached | `collector_test`: `test_a_session_started_from_the_terminal_is_never_read_listed_or_typed_into`, `test_a_by_named_session_busyyaks_did_not_launch_is_never_touched`, `test_a_record_of_another_process_is_no_proof` · `launcher_attach_test`: `test_a_session_busyyaks_did_not_start_is_never_attached` |
| U5 | `kanban_register type: lead` from a session busyyaks did not launch → refused | `mcp_kanban_test`: `test_a_terminal_session_never_becomes_the_lead_only_busyyaks_launch_does` · engine `lead_first_test` |
| U6 | a rule saved from the web lands in `<repo>/.busyyaks/skills/agents/<type>.md` | `project_agent_rules_test`: `test_the_projects_agent_markdown_lives_in_its_dot_busyyaks_directory_not_in_the_database` |
| U6 | … in that type's launched stage only (not the lead's, not another project's), any harness | **`project_agent_rules_test`: `test_a_rule_saved_for_one_agent_type_reaches_only_that_types_sessions_of_this_project`** · `launcher_trust_test`: `test_a_session_busyyaks_launches_as_lead_gets_that_types_rules_for_this_project`, `test_a_hermes_launch_gets_the_same_rules` |
| U6 | the launch budget the Settings tab shows | `launcher_trust_test`: `test_the_launcher_says_what_a_launch_does_with_the_projects_layer` · `project_agent_rules_test`: `test_a_rule_that_would_make_the_launch_refuse_is_refused_on_save` |
| U7 | nothing busyyaks in `~/.claude*`, `~/.hermes`, `~/.codex` | **`launcher_trust_test`: `test_a_launch_writes_nothing_into_any_harness_settings_of_the_user`** (hermes config byte for byte, HOME empty) · **`setup_test`: `test_installing_writes_nothing_into_any_harness_settings_or_a_projects_auto_loaded_files`** · **`no_global_skill_test`: the three repo scans above** |
| U8 | a `busyyaks-by_*` scope with no session is stopped by the `sessions` op, logged | **`launcher_trust_test`: `test_a_busyyaks_sessions_background_processes_are_stopped_once_the_session_ended`** (stub systemctl: only the ended session's scope; systemctl down → skipped, said) · `launcher_rules_test`: `test_stale_scopes_are_the_busyyaks_scopes_of_ended_sessions` |
| U9 | a ping during the start is retried, never lost | **`collector_test`: `test_a_ping_that_arrives_while_a_session_is_still_starting_is_retried_never_lost`** (a launch held at `tmux new-session` by the test: `notify` → retry "still starting", nothing typed; after the start ended → `gone`, never `unsupported`) · `launcher_rules_test`: `test_a_ping_during_the_start_is_retried_never_dropped` |
| U10 | an update keeps working | `cli_update_test`, `launcher_update_test` |

Harness: `test/support/collector_sandbox.rb` (moved out of `collector_test`, shared with `session_isolation_test`).

## Needs e2e (AI sessions)

What only a real harness or model can show — the tests above prove what busyyaks writes, hands over and refuses, not
what a CLI does with it.

| # | check | why it needs a real session |
|---|---|---|
| U1 | a hand-run `claude` / `hermes` / `codex` lists no busyyaks skill, MCP server or `kanban_*` tool, and its context holds no busyyaks text | what a harness loads (parent-dir CLAUDE.md / AGENTS.md, user settings, plugins, its auto-memory) is the harness's own discovery; the tests cover only this repo's files and what busyyaks writes |
| U1 | other projects carry no board rules in files a CLI loads (a harness's auto-memory, another repo's `AGENTS.md`) | the state of other repos and of the harness's memory, outside this repo's code |
| U2 | the launched claude runs `/busyyaks:session` from `--plugin-dir` and reaches the board MCP from `--mcp-config` (every board tool) | Claude Code's plugin and MCP loading; the tests stop at the argv, the stage files and the stub agent's /proc |
| U2 | a hermes launch loads its overlay's MCP and `busyyaks-session` from `skills.external_dirs` | the tests run a stub hermes answering like v0.21.5; a new hermes may resolve them otherwise |
| U4 | `/busyyaks:session` in a hand-run session → "Unknown command" | the harness's answer to a command it has no plugin for |
| U5 | a hand-run session has no board MCP to call `kanban_register` with at all | the harness's MCP config; the refusal itself is unit-tested |
| U6 | the launched Sub team follows its `team.md` rule | model behaviour |
| U9 | the retried ping is typed into the real claude once it is up and the agent acts on it | the tests end at the launcher's retry answer and the collector's paste into a stub pane |

Not AI, but a real host (outside unit tests): U7's live grep of the operator's own `~/.claude.json` / `~/.hermes` /
`~/.codex` (machine state, not code); U8's scope stop ending real processes in a systemd user manager's cgroup (CI's
install machine has one); the page screenshots (visual); "never read" on a host whose `agents.collector` is another
program than busyyaks's `bin/collector` (another collector may read every pane — busyyaks filters its snapshot, but
the reading itself is that program's; proven only for `bin/collector`).
