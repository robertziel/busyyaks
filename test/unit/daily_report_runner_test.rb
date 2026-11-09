# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "yaml"
require "busyyaks/mcp_server"

# the hermes runner, run with a stub command — the generated Hermes config carries the gateway as the only
# provider, the configured models / context / children; no terminal, no process tool, no git — every fact comes over
# the busyyaks MCP, so a repo's config or a commit message cannot run a program on the host.
class DailyReportRunnerTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_hermes_runner_writes_its_config_and_runs_the_command
    Dir.mktmpdir do |d|
      stub = File.join(d, "stub")
      token = "tok-#{'s' * 40}"
      File.write(File.join(d, "token"), token)
      # the stub (Hermes) records whether it got the bearer in its environment, and every cmdline on the box that
      # holds it while the runner runs (its own process tree included)
      File.write(stub, <<~SH)
        #!/bin/sh
        [ "$BUSYYAKS_MCP_TOKEN" = "$(cat #{d}/token)" ] && echo env-ok > #{d}/probe
        grep -l -a -F -f #{d}/token /proc/[0-9]*/cmdline 2>/dev/null >> #{d}/probe
        printf '%s\n' "HOME=$HERMES_HOME" "$@"
      SH
      File.chmod(0o755, stub)
      env = { "DAY" => "2026-01-15", "GATEWAY" => "http://g/v1", "LEAD_MODEL" => "lead-m", "AGENT_MODEL" => "child-m",
              "CONTEXT_LENGTH" => "4096", "MCP_URL" => "http://m/mcp", "BUSYYAKS_MCP_TOKEN_FILE" => "#{d}/token",
              "USAGE_FILE" => "#{d}/u.json", "BUSYYAKS_DIR" => ROOT, "RUNNER_COMMAND" => stub,
              "RUNNER_HOME" => "#{d}/home", "RUNNER_MAX_CHILDREN" => "3", "PATH" => "#{RbConfig::CONFIG["bindir"]}:/usr/bin:/bin", }
      out, err, st = Open3.capture3(env, File.join(ROOT, "bin/daily-report-runners/hermes"), unsetenv_others: true)
      assert st.success?, err
      assert_equal "env-ok\n", File.read("#{d}/probe"), "the bearer reaches Hermes's env and no cmdline holds it"
      refute_includes File.read("#{d}/home/config.yaml"), token, "the config reads it from the env, never the value"
      lines = out.lines(chomp: true)
      assert_equal "HOME=#{d}/home", lines[0]
      assert_equal "-z", lines[1]
      assert_includes lines[2], "daily reporter for 2026-01-15"
      assert_equal ["--ignore-rules", "-t", "delegation,busyyaks", "--usage-file", "#{d}/u.json"], lines.last(5),
                   "toolsets: delegation + the busyyaks MCP only — no terminal"
      prompt = lines[2..-6].join("\n")
      assert_includes prompt, %(toolsets=["busyyaks"]), "children get the busyyaks MCP only"
      refute_match(/git -C|toolsets=\["terminal"\]|PROJECTS_(ROOT|MOUNT)/, prompt)
      assert_includes prompt, "dirty_paths"
      assert_includes prompt, "churn.commits"
      y = File.read("#{d}/home/config.yaml")
      assert_includes y, %(default: "lead-m")
      assert_includes y, %(model: "child-m")
      assert_includes y, "context_length: 4096"
      assert_includes y, "max_concurrent_children: 3"
      refute_match(/hooks|pre_tool_call|terminal|process_manage|guard/, y, "no hook and no terminal in the generated config")
      assert_equal 3, y.scan(%(base_url: "http://g/v1")).size, "lead, children and compression all on the gateway"
      assert_equal 2, y.scan("fallback_providers: []").size
      # Hermes gets exactly the busyyaks tools its prompt calls, all within the report token's REPORT_TOOLS
      include = YAML.safe_load(y).dig("mcp_servers", "busyyaks", "tools", "include")
      used = File.read(File.join(ROOT, "bin/daily-report-runners/hermes")).scan(/mcp__busyyaks__([a-z_]+)/).flatten.uniq
      assert_equal used.sort, include.sort
      assert_empty include - Busyyaks::McpServer::REPORT_TOOLS
    end
  end

  # the host side runs no git either: no git call, no repo path handed to the runner
  def test_no_host_git_in_the_daily_report_scripts
    %w[bin/daily-report bin/daily-report-runners/hermes].each do |f|
      src = File.read(File.join(ROOT, f))
      refute_match(/^\s*[^#\n]*\bgit\s+-C\b/, src, f)
      refute_match(/PROJECTS_(ROOT|MOUNT)/, src, f)
    end
    refute_path_exists File.join(ROOT, "bin/daily-report-git-guard")
  end

  def test_hermes_runner_refuses_a_missing_variable
    _, err, st = Open3.capture3({ "PATH" => "/usr/bin:/bin" }, File.join(ROOT, "bin/daily-report-runners/hermes"),
                                unsetenv_others: true)
    refute st.success?
    assert_match(/DAY/, err)
  end

  # The host runs bin/daily-report-runners/<runner.type>; the type comes from the MCP container's answer, so the host
  # checks it is a runner NAME (never a path) and an executable file there before it runs anything. (jq is not in the
  # test image: this reads the check; the PR's receipt ran it against a stub MCP.)
  def test_daily_report_checks_the_runner_type_on_the_host
    src = File.read(File.join(ROOT, "bin/daily-report"))
    check = src.index('[[ "$runner_type" =~ ^[a-z][a-z0-9_-]*$ ]]')
    assert check, "bin/daily-report checks runner.type against ^[a-z][a-z0-9_-]*$"
    assert_operator check, :<, src.index('runner="$PWD/bin/daily-report-runners/$runner_type"')
    assert_includes src, '{ [ -f "$runner" ] && [ -x "$runner" ]; } || config_error'
  end

  # bin/daily-report hands the runner its bearer as a 0600 file in a private dir (removed on exit), never an argv:
  # timeout(1) and env(1) keep their argv, readable by every user in /proc, for the whole run
  def test_daily_report_passes_the_bearer_as_a_file
    src = File.read(File.join(ROOT, "bin/daily-report"))
    run = src[/^timeout --kill-after.*?"\$runner" >>/m]
    refute_nil run
    refute_includes run, "$MCP_REPORT_TOKEN"
    assert_includes run, 'BUSYYAKS_MCP_TOKEN_FILE="$token_file"'
    assert_includes src, %(secret_dir=$(mktemp -d "${TMPDIR:-/tmp}/busyyaks-daily.XXXXXXXX"))
    assert_includes src, %(trap 'rm -rf "$secret_dir"' EXIT)
    assert_includes src, %((umask 077 && printf '%s' "$MCP_REPORT_TOKEN" >"$token_file"))
  end

  # no report from a stale or failed scan: bin/daily-report asks daily_facts and posts FAILED with the reason
  # (the decision is ScanFreshness.refusal, tested in scan_freshness_test)
  def test_daily_report_refuses_a_stale_scan
    src = File.read(File.join(ROOT, "bin/daily-report"))
    gate = src.index("Busyyaks::ScanFreshness.refusal")
    assert gate
    assert_operator gate, :<, src.index('"$runner" >>"$log"'), "checked before the runner starts"
    assert_includes src, %(post "Daily report $day FAILED" "\\`bad:stale scan\\` $scan_refusal")
    # before the cutoff (and not --force): logged, exit 0, nothing posted — the next tick retries
    gate_block = src[/if \[ -n "\$scan_refusal" \]; then.*?\nfi\n/m]
    assert_includes gate_block, %(if [ "$force" -eq 0 ] && [[ $(date +%H:%M) < "$cutoff" ]]; then exit 0; fi)
    assert_operator gate_block.index("exit 0"), :<, gate_block.index("post ")
  end
end
