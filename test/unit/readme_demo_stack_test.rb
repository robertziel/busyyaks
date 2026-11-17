# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

# The README screenshots' stage (scripts/readme-images/demo-stack) writes its own .env and config/busyyaks.yml. Every
# key compose requires and every key the config loader requires has no default, so a key added to .env.example or to
# config/busyyaks.example.yml and not to the stage stops it from booting. These
# keep the two in step.
class ReadmeDemoStackTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  STACK = File.read(File.join(ROOT, "scripts/readme-images/demo-stack"))
  # only bin/render-deploy reads the reverse-proxy keys; only scripts/ci/test.sh reads the CI ones
  NOT_THE_STACKS = %w[TLS_CERT_PATH TLS_KEY_PATH PROXY_UPSTREAM FRPC_SUBDOMAIN CI_GITHUB_READ_TOKEN CI_GITHUB_CACHE_DIR].freeze
  # optional in the loader: a deployment adds engines, the daily-report runners it may execute
  OPTIONAL_CONFIG = %w[engines daily_report_runners].freeze

  def heredoc(marker, tag)
    body = STACK[/#{Regexp.escape(marker)} <<#{tag}\n(.*?)\n#{tag}\n/m, 1]
    refute_nil body, "demo-stack has no `#{marker} <<#{tag}` heredoc"
    body.gsub(/\$\w+|\$\([^)]*\)/, "x")
  end

  def keys_of_env(text) = text.lines.grep(/\A[A-Z][A-Z0-9_]*=/).map { |l| l[/\A[A-Z0-9_]+/] }

  def test_the_stage_env_has_every_env_example_key
    example = keys_of_env(File.read(File.join(ROOT, ".env.example")))
    stage = keys_of_env(heredoc('cat > "$w/.env"', "ENV"))
    assert_empty example - NOT_THE_STACKS - stage, "keys of .env.example the README demo stage does not write"
  end

  def test_the_stage_config_has_every_required_config_key
    example = YAML.safe_load_file(File.join(ROOT, "config/busyyaks.example.yml"))
    stage = YAML.safe_load(heredoc('cat > "$w/config/busyyaks.yml"', "YML"))
    assert_empty example.keys - OPTIONAL_CONFIG - stage.keys, "config keys the README demo stage does not write"
    assert_empty example.fetch("launch").keys - stage.fetch("launch").keys, "launch keys the stage does not write"
  end

  # the stand-in agent is the stage's one launch command: seed.js makes it every type's launcher
  def test_the_stage_launches_only_its_stand_in_agent
    stage = YAML.safe_load(heredoc('cat > "$w/config/busyyaks.yml"', "YML"))
    assert_equal [{ "kind" => "hermes", "command" => "readme-agent", "args" => [], "via_shell" => false }],
                 stage.dig("launch", "commands")
    assert_includes File.read(File.join(ROOT, "scripts/readme-images/seed.js")), 'command: "readme-agent"'
  end

  # The stand-ins never substitute: a session without the screen build gives it is an error, named.
  def with_collector_dir
    Dir.mktmpdir("readme-demo") do |d|
      FileUtils.mkdir_p(File.join(d, "kinds"))
      yield d
    end
  end

  # the collector's kind / status / waiting_for, cut out of the script and run on their own
  def collector_functions(dir)
    src = File.read(File.join(ROOT, "scripts/readme-images/collector"))
    body = src[/^kind\(\) \{.*?(?=^# status_at)/m]
    refute_nil body, "the collector's kind() … waiting_for() block moved"
    "out=#{dir}\n#{body}"
  end

  def run_collector(dir, call) = Open3.capture3("sh", "-c", "#{collector_functions(dir)}\n#{call}")

  def test_the_collector_refuses_a_session_without_a_kind
    with_collector_dir do |d|
      %w[status waiting_for].each do |fn|
        out, err, st = run_collector(d, "#{fn} acme_storefront_worker")
        refute st.success?, "#{fn} answered #{out.inspect} for a session with no kind"
        assert_includes err, "session acme_storefront_worker has no screen kind"
      end
    end
  end

  def test_the_collector_reads_each_kind
    with_collector_dir do |d|
      { "thinking" => ['"busy"', "null"], "permission" => ['"busy"', '"permission"'], "idle" => ['"idle"', "null"] }
        .each do |kind, (status, waiting)|
          File.write(File.join(d, "kinds", "s"), "#{kind}\n")
          assert_equal [status, waiting], [run_collector(d, "status s")[0].strip, run_collector(d, "waiting_for s")[0].strip]
        end
      File.write(File.join(d, "kinds", "s"), "dancing\n")
      _, err, st = run_collector(d, "status s")
      refute st.success?
      assert_includes err, "unknown screen kind dancing"
    end
  end

  # the stand-in agent with no screen exits, naming the file (bin/launcher's start check then refuses the launch)
  def test_the_agent_exits_without_its_screen
    Dir.mktmpdir("readme-agent") do |d|
      FileUtils.mkdir_p(File.join(d, "bin"))
      File.write(File.join(d, "bin", "tmux"), "#!/bin/sh\necho acme_storefront_team\n")
      File.chmod(0o755, File.join(d, "bin", "tmux"))
      agent = File.read(File.join(ROOT, "scripts/readme-images/agent")).gsub("@COLLECTOR@", d)
      _, err, st = Open3.capture3({ "PATH" => "#{d}/bin:#{ENV.fetch('PATH')}" }, "sh", "-c", agent)
      refute st.success?
      assert_includes err, "no screen for session acme_storefront_team (#{d}/screens/acme_storefront_team"
    end
  end

  # the snapshot with no tmux server is "no sessions"; any other tmux failure fails it (no empty list in its place)
  def run_snapshot(dir, tmux_err)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "tmux"), "#!/bin/sh\necho '#{tmux_err}' >&2\nexit 1\n")
    File.chmod(0o755, File.join(dir, "bin", "tmux"))
    snapshot = File.read(File.join(ROOT, "scripts/readme-images/collector"))[/^snapshot\(\) \{.*?^\}\n/m]
    refute_nil snapshot, "the collector's snapshot() moved"
    Open3.capture3({ "PATH" => "#{dir}/bin:#{ENV.fetch('PATH')}" }, "sh", "-c",
                   "#{collector_functions(dir)}\n#{snapshot}\nsnapshot")
  end

  def test_the_collector_snapshot_without_a_tmux_server_has_no_sessions
    ["no server running on /tmp/tmux-1000/default",
     "error connecting to /tmp/tmux-1000/default (No such file or directory)",].each do |msg|
      with_collector_dir do |d|
        out, err, st = run_snapshot(d, msg)
        assert st.success?, err
        assert_equal [], JSON.parse(out)["sessions"]
      end
    end
  end

  def test_the_collector_snapshot_fails_on_any_other_tmux_error
    with_collector_dir do |d|
      out, err, st = run_snapshot(d, "error connecting to /tmp/tmux-1000/default (Permission denied)")
      refute st.success?, "snapshot answered #{out.inspect}"
      assert_includes err, "collector: tmux list-panes: error connecting"
    end
  end

  # the read socket takes no input for the stand-in: a ping is refused, never answered ok
  def test_the_collector_refuses_send
    src = File.read(File.join(ROOT, "scripts/readme-images/collector"))
    assert_match(/when "send" then \{ ok: false/, src)
  end
end
