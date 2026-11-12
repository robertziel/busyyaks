# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "json"
require "fileutils"

# bin/daily-report itself, run in a sandbox copy of the checkout's script with a stub busyyaks
# MCP (a `curl` on PATH that answers the tools from files) and a stub deploy/install-daily-timer.sh — the titles it
# posts and its exit codes, not its source text.
class DailyReportTickTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CFG = { "schedule" => "*-*-* *:00/10:00", "cutoff" => "23:59", "probe_timeout" => 2, "run_timeout" => "90m",
          "gateway" => "http://gateway.invalid/v1", "model" => "m", "agent_model" => "m", "context_length" => 10,
          "runner" => { "type" => "hermes", "command" => "hermes", "home" => "/h", "max_children" => 2 }, }.freeze
  STAMP = { "command" => "hermes", "run_timeout" => "90m", "schedule" => "*-*-* *:00/10:00" }.freeze

  # the stub curl: MCP tools/call by name; anything else (the gateway probe) fails like an unreachable host
  CURL = <<~'SH'
    #!/usr/bin/env bash
    body=""; while [ $# -gt 0 ]; do [ "$1" = -d ] && body=$2; shift; done
    [ -n "$body" ] && name=$(jq -r '.params.name // empty' <<<"$body") || name=""
    [ -n "$name" ] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }
    echo "$name" >>"$S/calls"
    ok() { jq -cn --arg t "$1" '{result:{isError:false,content:[{type:"text",text:$t}]}}'; }
    case $name in
      daily_report_config)
        if [ -f "$S/cfg.json" ]; then ok "$(jq -c '{configured:true,config:.}' "$S/cfg.json")"
        else ok '{"configured":false,"reason":"no daily report settings saved: Settings → Daily report"}'; fi ;;
      list_reports) ok "$(jq -c . "$S/reports.json")" ;;
      post_report)
        jq -c --arg t "$(jq -r .params.arguments.title <<<"$body")" --arg b "$(jq -r .params.arguments.body_markdown <<<"$body")" \
          '. + [{title:$t,body:$b}]' "$S/reports.json" >"$S/r.tmp" && mv "$S/r.tmp" "$S/reports.json"; ok '{}' ;;
      *) exit 7 ;;
    esac
  SH

  def setup
    super
    @s = Dir.mktmpdir("tick")
    box = File.join(@s, "box")
    FileUtils.mkdir_p(%W[#{box}/bin/daily-report-runners #{box}/deploy #{box}/data #{@s}/shim])
    FileUtils.cp(File.join(ROOT, "bin/daily-report"), "#{box}/bin/")
    write("#{box}/bin/env", "#!/bin/sh\necho MCP_HOST=x; echo MCP_HOST_PORT=1; echo MCP_REPORT_TOKEN=t; echo TZ=UTC\n")
    write("#{box}/bin/daily-report-runners/hermes", "#!/bin/sh\necho runner-ran >>\"$S/calls\"\n")
    write("#{box}/deploy/install-daily-timer.sh", <<~SH)
      #!/bin/sh
      echo install >>"$S/calls"
      [ -f "$S/install-fails" ] && { echo "systemd-analyze: bad calendar" >&2; exit 1; }
      jq -cS '{schedule, run_timeout, command: .runner.command}' "$S/cfg.json" >data/daily-timer.json
    SH
    write("#{@s}/shim/curl", CURL)
    reports([])
  end

  def teardown
    FileUtils.rm_rf(@s)
    super
  end

  def write(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def day = Time.now.utc.strftime("%F")
  def reports(list) = File.write(File.join(@s, "reports.json"), JSON.generate(list))
  def titles = JSON.parse(File.read(File.join(@s, "reports.json"))).map { _1["title"] }
  def calls = File.exist?(File.join(@s, "calls")) ? File.read(File.join(@s, "calls")).split("\n") : []
  def configure(cfg = CFG) = File.write(File.join(@s, "cfg.json"), JSON.generate(cfg))
  def stamp(h = STAMP) = File.write(File.join(@s, "box/data/daily-timer.json"), JSON.generate(h))

  def tick
    File.delete(File.join(@s, "calls")) if File.exist?(File.join(@s, "calls"))
    env = { "S" => @s, "PATH" => "#{@s}/shim:#{ENV.fetch('PATH')}", "TZ" => "UTC" }
    _, err, st = Open3.capture3(env, "bin/daily-report", chdir: File.join(@s, "box"))
    [st.exitstatus, err]
  end

  def test_not_configured_posts_one_visible_report_a_day
    code, err = tick
    assert_equal 2, code
    assert_includes err, "daily report not configured: no daily report settings saved"
    assert_equal ["Daily report #{day} NOT CONFIGURED"], titles
    body = JSON.parse(File.read(File.join(@s, "reports.json"))).first["body"]
    assert_includes body, "`bad:not configured` no daily report settings saved: Settings → Daily report"
    assert_includes body, "saves the settings; the next tick runs the report."
    assert_equal 2, tick.first
    assert_equal 1, titles.size, "the second tick posts nothing"
    refute_includes calls, "post_report"
  end

  def test_not_configured_on_a_day_that_already_has_a_report_posts_nothing
    reports([{ title: "Daily report #{day}" }])
    assert_equal 2, tick.first
    assert_equal ["Daily report #{day}"], titles
  end

  def test_settings_saved_after_a_not_configured_report_run_the_same_day
    reports([{ title: "Daily report #{day} NOT CONFIGURED" }])
    configure
    stamp
    assert_equal 0, tick.first
    assert_includes File.read(File.join(@s, "box/data/daily-report-#{day}.log")), "vLLM offline", "past step 1 to the probe"
    refute_includes calls, "install"
  end

  def test_a_real_report_today_is_a_silent_exit
    reports([{ title: "Daily report #{day} NOT CONFIGURED" }, { title: "Daily report #{day}" }])
    configure
    stamp
    code, err = tick
    assert_equal [0, ""], [code, err]
    assert_equal %w[daily_report_config list_reports], calls
  end

  def test_the_units_are_reinstalled_only_when_the_settings_differ
    reports([{ title: "Daily report #{day}" }])
    configure
    assert_equal 0, tick.first
    assert_equal 1, calls.count("install"), "no record yet → installed"
    assert_equal STAMP, JSON.parse(File.read(File.join(@s, "box/data/daily-timer.json")))
    assert_equal 0, tick.first
    assert_equal 0, calls.count("install"), "same settings → left alone"
    configure(CFG.merge("run_timeout" => "2h"))
    assert_equal 0, tick.first
    assert_equal 1, calls.count("install"), "run_timeout changed → reinstalled"
  end

  def test_an_installer_refusal_is_not_configured_saying_why
    configure(CFG.merge("schedule" => "Mon *-*-* 99:00"))
    stamp
    FileUtils.touch(File.join(@s, "install-fails"))
    code, err = tick
    assert_equal 2, code
    assert_includes err, "deploy/install-daily-timer.sh refused the settings"
    assert_equal ["Daily report #{day} NOT CONFIGURED"], titles
    assert_includes File.read(File.join(@s, "box/data/daily-report-#{day}.log")), "systemd-analyze: bad calendar"
    body = JSON.parse(File.read(File.join(@s, "reports.json"))).first["body"]
    assert_includes body, "Fix the setting it names on Settings → Daily report (the cog menu); the next tick retries."
    refute_includes body, "the next tick runs the report", "a refused setting is refused again until it changes"
    refute_includes calls, "runner-ran"
  end
end
