# frozen_string_literal: true

# Standalone (no test_helper, no app): `yaks` is a host program, and this file also runs on the oldest host Ruby it
# supports (scripts/ci/test.sh host).
require "minitest/autorun"
require "minitest/mock"
require "fileutils"
require "socket"
require "stringio"
require "tmpdir"
require_relative "../../cli/yaks"

# cli/yaks.rb in-process: each command's exact argv, its output, its exit code and every refusal.
class CliTest < Minitest::Test
  CLI = Busyyaks::CLI

  # records every spawn; `which` finds the names in `tools`; `capture` answers from `answers` (argv prefix → [out, ok])
  class FakeRunner
    attr_reader :calls

    def initialize(tools: %w[docker git tmux claude systemctl xdg-open jq curl flock timeout], answers: {}, system: true)
      @tools = tools
      @answers = answers
      @system = system
      @calls = []
    end

    def which(name) = @tools.include?(name) ? "/usr/bin/#{name}" : nil

    def system(*argv)
      @calls << [:system, argv]
      @system
    end

    def capture(*argv)
      @calls << [:capture, argv]
      @answers.find { |prefix, _| argv.first(prefix.size) == prefix }&.last || ["", true]
    end

    def exec(*argv)
      @calls << [:exec, argv]
    end
  end

  # answers per path; raises Down for a path in `down`
  class FakeHttp
    attr_reader :calls

    def initialize(answers, down: [])
      @answers = answers
      @down = down
      @calls = []
    end

    def get(host, port, path, headers) = answer(:get, host, port, path, headers)

    def post(host, port, path, headers, body) = answer(:post, host, port, path, headers, body)

    def answer(*call)
      @calls << call
      raise CLI::Http::Down, "#{call[1]}:#{call[2]}: Connection refused" if @down.include?(call[3])

      @answers.fetch(call[3])
    end
  end

  ENV_FILE = <<~ENV
    PUBLIC_HOST=
    WEB_HOST_PORT=8080
    MCP_HOST=127.0.0.1
    MCP_HOST_PORT=8081
    MCP_TOKEN=secret-token
    LAUNCHER_RUN_DIR=%<run>s
  ENV

  def setup
    @home = Dir.mktmpdir("yaks-home")
    @run = File.join(@home, "run")
    FileUtils.mkdir_p([@run, File.join(@home, "config")])
    File.write(File.join(@home, ".env"), format(ENV_FILE, run: @run))
    File.write(File.join(@home, "config/busyyaks.yml"), "roots: []\n")
    @runner = FakeRunner.new
    @http = FakeHttp.new({ "/up" => [200, "ok"], "/mcp" => [200, JSON.generate(result: { tools: [{}, {}, {}] })] })
  end

  def teardown
    FileUtils.rm_rf(@home)
  end

  def yaks(*argv, os: "Linux", ruby: "3.4.1", env: { "PATH" => "/usr/bin", "DISPLAY" => ":0" })
    out = StringIO.new
    err = StringIO.new
    code = CLI.run(argv, home: @home, env: env, out: out, err: err, os: os, ruby: ruby,
                         runner: @runner, http: @http)
    [code, out.string, err.string]
  end

  def compose(*args) = ["docker", "compose", "--project-directory", @home, "-f", "#{@home}/docker-compose.yml", *args]

  def test_help_lists_every_command
    code, out, = yaks("help")
    assert_equal 0, code
    CLI::COMMANDS.each { |c, _| assert_includes out, "yaks #{c}" }
  end

  def test_usage_errors_exit_2_with_the_usage
    [[], ["bogus"], %w[server], %w[server bogus], %w[env], %w[panel extra], %w[panel --nope], %w[server status x],
     %w[server logs bogus], %w[server logs web mcp], %w[doctor x],].each do |argv|
      code, out, err = yaks(*argv)
      assert_equal 2, code, argv.inspect
      assert_empty out
      assert_includes err, "usage: yaks <command>", argv.inspect
    end
  end

  def test_only_linux_and_a_new_enough_ruby
    code, _, err = yaks("help", os: "Darwin")
    assert_equal 1, code
    assert_includes err, "busyyaks runs on Linux only"
    assert_includes err, "this is Darwin"
    code, _, err = yaks("help", ruby: "3.1.9")
    assert_equal 1, code
    assert_includes err, "Ruby 3.1.9 is older than #{CLI::MIN_RUBY}"
    assert_empty @runner.calls
  end

  def test_env_prints_exports_and_refuses_a_missing_key
    code, out, = yaks("env", "WEB_HOST_PORT", "MCP_TOKEN")
    assert_equal 0, code
    assert_equal "export WEB_HOST_PORT='8080'\nexport MCP_TOKEN='secret-token'\n", out
    code, out, err = yaks("env", "PUBLIC_HOST")
    assert_equal 1, code
    assert_empty out
    assert_includes err, "missing or empty PUBLIC_HOST"
  end

  def test_a_missing_or_malformed_env_is_refused
    File.write(File.join(@home, ".env"), "A=$B\n")
    code, _, err = yaks("panel", "--print")
    assert_equal 1, code
    assert_includes err, "variable interpolation is not supported"
    File.delete(File.join(@home, ".env"))
    code, _, err = yaks("env", "A")
    assert_equal 1, code
    assert_includes err, "no .env at #{@home}/.env"
  end

  def test_panel_opens_the_dashboard_origin
    code, out, = yaks("panel")
    assert_equal 0, code
    assert_empty out
    assert_equal [[:system, ["xdg-open", "http://127.0.0.1:8080"]]], @runner.calls
  end

  # over ssh / in tmux: refused at once, naming why and the URL; --print still works there
  def test_panel_needs_a_graphical_session
    code, out, err = yaks("panel", env: { "PATH" => "/usr/bin" })
    assert_equal [1, ""], [code, out]
    assert_includes err, "no graphical session here (DISPLAY and WAYLAND_DISPLAY are unset)"
    assert_includes err, "yaks panel --print for the URL (http://127.0.0.1:8080)"
    assert_empty @runner.calls, "xdg-open is not tried"
    assert_equal 0, yaks("panel", env: { "PATH" => "/usr/bin", "WAYLAND_DISPLAY" => "wayland-0" }).first
    assert_equal [[:system, ["xdg-open", "http://127.0.0.1:8080"]]], @runner.calls
    assert_equal [0, "http://127.0.0.1:8080\n"], yaks("panel", "--print", env: { "PATH" => "/usr/bin" }).first(2)
  end

  def test_panel_print_uses_the_public_host
    File.write(File.join(@home, ".env"), format(ENV_FILE, run: @run).sub("PUBLIC_HOST=", "PUBLIC_HOST=dash.example.com"))
    code, out, = yaks("panel", "--print")
    assert_equal 0, code
    assert_equal "https://dash.example.com\n", out
    assert_empty @runner.calls
  end

  def test_panel_fails_when_the_opener_fails_or_the_url_is_malformed
    @runner = FakeRunner.new(system: false)
    code, _, err = yaks("panel")
    assert_equal 1, code
    assert_includes err, "xdg-open failed to open http://127.0.0.1:8080"
    File.write(File.join(@home, ".env"), format(ENV_FILE, run: @run).sub("WEB_HOST_PORT=8080", "WEB_HOST_PORT=0"))
    code, _, err = yaks("panel", "--print")
    assert_equal 1, code
    assert_includes err, 'WEB_HOST_PORT="0" is not a port'
  end

  def test_server_logs_execs_compose_logs
    assert_equal 0, yaks("server", "logs").first
    assert_equal 0, yaks("server", "logs", "-f", "web").first
    assert_equal 0, yaks("server", "logs", "postgres").first
    assert_equal [[:exec, compose("logs")], [:exec, compose("logs", "--follow", "web")],
                  [:exec, compose("logs", "postgres")],], @runner.calls
  end

  def test_server_status_all_up
    sock = UNIXServer.new(File.join(@run, "launcher.sock"))
    @runner = FakeRunner.new(answers: { compose("ps") => ["web\nmcp\nscanner\ngithub\nnotifier\n", true],
                                        %w[systemctl --user is-active] => ["active\n", true], })
    code, out, = yaks("server", "status")
    assert_equal 0, code, out
    assert_match(/^ok    web\s+running$/, out)
    assert_match(%r{^ok    web /up\s+HTTP 200$}, out)
    assert_match(%r{^ok    mcp tools/list\s+3 tools$}, out)
    assert_match(/^ok    busyyaks-launcher.service\s+active$/, out)
    assert_match(%r{^ok    launcher socket\s+#{Regexp.escape(@run)}/launcher.sock$}, out)
    assert_includes @runner.calls, [:capture, compose("ps", "--services", "--status", "running")]
    get, post = @http.calls
    assert_equal [:get, "127.0.0.1", "8080", "/up", { "Host" => "127.0.0.1:8080" }], get
    assert_equal ["127.0.0.1", "8081", "/mcp"], post[1, 3]
    assert_equal "Bearer secret-token", post[4].fetch("Authorization")
    assert_equal "tools/list", JSON.parse(post[5]).fetch("method")
  ensure
    sock&.close
  end

  def test_server_status_reports_each_failure_and_exits_1
    @runner = FakeRunner.new(answers: { compose("ps") => ["web\n", true],
                                        %w[systemctl --user is-active] => ["inactive\n", false], })
    @http = FakeHttp.new({ "/mcp" => [401, "bearer token required"] }, down: ["/up"])
    code, out, = yaks("server", "status")
    assert_equal 1, code
    assert_match(/^ok    web\s+running$/, out)
    assert_match(/^FAIL  mcp\s+not running$/, out)
    assert_match(%r{^FAIL  web /up\s+127.0.0.1:8080: Connection refused$}, out)
    assert_match(%r{^FAIL  mcp tools/list\s+HTTP 401$}, out)
    assert_match(/^FAIL  busyyaks-launcher.service\s+inactive$/, out)
    assert_match(/^FAIL  launcher socket\s+.*launcher.sock: no socket$/, out)
  end

  def test_server_status_when_compose_fails_or_mcp_answers_garbage
    @runner = FakeRunner.new(answers: { compose("ps") => ["", false], %w[systemctl] => ["", false] })
    @http = FakeHttp.new({ "/up" => [200, ""], "/mcp" => [200, "<html>"] })
    code, out, = yaks("server", "status")
    assert_equal 1, code
    assert_match(/^FAIL  compose\s+docker compose ps failed$/, out)
    assert_match(%r{^FAIL  mcp tools/list\s+the answer is not JSON$}, out)
    assert_match(/^FAIL  busyyaks-launcher.service\s+systemctl --user is-active failed$/, out)
    @http = FakeHttp.new({ "/up" => [200, ""], "/mcp" => [200, "{}"] })
    _, out, = yaks("server", "status")
    assert_match(%r{^FAIL  mcp tools/list\s+no tools in the answer$}, out)
    %w[[] null 7].each do |json|
      @http = FakeHttp.new({ "/up" => [200, ""], "/mcp" => [200, json] })
      code, out, err = yaks("server", "status")
      assert_equal [1, ""], [code, err], json
      assert_match(%r{^FAIL  mcp tools/list\s+the answer is not a JSON object$}, out, json)
    end
    @http = FakeHttp.new({}, down: ["/up", "/mcp"])
    _, out, = yaks("server", "status")
    assert_match(%r{^FAIL  mcp tools/list\s+127.0.0.1:8081: Connection refused$}, out)
  end

  # a port that is not one, or an MCP_HOST off loopback (the bearer would leave the box): refused before any request
  def test_server_status_refuses_malformed_ports_and_a_non_loopback_mcp_host
    { "WEB_HOST_PORT=8080" => "WEB_HOST_PORT=abc", "MCP_HOST_PORT=8081" => "MCP_HOST_PORT=99999" }.each do |from, to|
      File.write(File.join(@home, ".env"), format(ENV_FILE, run: @run).sub(from, to))
      code, out, err = yaks("server", "status")
      assert_equal [1, ""], [code, out], to
      key, value = to.split("=")
      assert_includes err, "yaks: .env: #{key} must be a port number 1-65535 (got #{value.inspect})"
    end
    File.write(File.join(@home, ".env"), format(ENV_FILE, run: @run).sub("MCP_HOST=127.0.0.1", "MCP_HOST=10.0.0.5"))
    code, _, err = yaks("server", "status")
    assert_equal 1, code
    assert_includes err, "yaks: .env: MCP_HOST must be an IPv4 loopback address"
    assert_empty @http.calls, "nothing was sent"
  end

  def test_server_status_needs_its_env_keys
    File.write(File.join(@home, ".env"), "WEB_HOST_PORT=8080\n")
    code, _, err = yaks("server", "status")
    assert_equal 1, code
    assert_includes err, ".env: missing or empty MCP_HOST, MCP_HOST_PORT, MCP_TOKEN, LAUNCHER_RUN_DIR"
  end

  def test_doctor_all_found
    @runner = FakeRunner.new(answers: { %w[docker compose version] => ["2.32.4\n", true] })
    code, out, = yaks("doctor")
    assert_equal 0, code, out
    assert_match(%r{^ok    docker\s+/usr/bin/docker\s+the stack}, out)
    assert_match(/^ok    docker compose\s+2.32.4\s/, out)
    assert_match(/^ok    systemd --user\s+running\s/, out)
    assert_match(/^ok    ruby\s+3.4.1 \(>= #{CLI::MIN_RUBY}\)/, out)
    refute_match(/^\S+\s+jq\s/, out, "no daily_report_runners: its tools are not asked")
    assert_match(%r{^ok    graphical session\s+DISPLAY / WAYLAND_DISPLAY set\s+yaks panel$}, out)
  end

  # yaks panel's needs are optional: a server without a desktop passes doctor
  def test_doctor_on_a_headless_server_passes_with_panel_marked_missing
    @runner = FakeRunner.new(tools: %w[docker git tmux claude systemctl],
                             answers: { %w[docker compose version] => ["2.32.4\n", true] })
    code, out, = yaks("doctor", env: { "PATH" => "/usr/bin" })
    assert_equal 0, code, out
    assert_match(/^miss  xdg-open\s+not on PATH\s+yaks panel$/, out)
    assert_match(%r{^miss  graphical session\s+none \(ssh / tmux\): yaks panel --print\s+yaks panel$}, out)
  end

  def test_doctor_names_what_is_missing
    File.write(File.join(@home, "config/busyyaks.yml"), "daily_report_runners: []\n")
    @runner = FakeRunner.new(tools: %w[git tmux claude], answers: {})
    code, out, = yaks("doctor")
    assert_equal 1, code
    assert_match(/^FAIL  docker\s+not on PATH\s+the stack/, out)
    assert_match(/^FAIL  docker compose\s+the compose plugin is missing/, out)
    assert_match(/^FAIL  systemd --user\s+no user manager/, out)
    assert_match(/^FAIL  jq\s+not on PATH\s+the daily report$/, out)
    assert_match(%r{^ok    git\s+/usr/bin/git}, out)
  end

  # the daily report's settings live in the database; a config still holding them is refused at boot
  def test_doctor_fails_a_config_with_the_moved_daily_report_block
    @runner = FakeRunner.new(answers: { %w[docker compose version] => ["2.32.4\n", true] })
    File.write(File.join(@home, "config/busyyaks.yml"), "daily_report: {}\ndaily_report_runners: []\n")
    code, out, = yaks("doctor")
    assert_equal 1, code
    assert_match(%r{^FAIL  config/busyyaks.yml\s+daily_report moved to Settings → Daily report}, out)
    refute_match(/^\S+\s+jq\s/, out, "a refused config: the daily tools are not asked")
  end

  # a config the user cannot read (EACCES) is a FAIL row, never a backtrace
  def test_doctor_reports_a_config_it_cannot_open_as_a_row
    @runner = FakeRunner.new(answers: { %w[docker compose version] => ["2.32.4\n", true] })
    File.write(File.join(@home, "config/busyyaks.yml"), "daily_report_runners: []\n")
    YAML.stub(:safe_load_file, ->(*) { raise Errno::EACCES, "config/busyyaks.yml" }) do
      code, out, err = yaks("doctor")
      assert_equal [1, ""], [code, err]
      assert_match(%r{^FAIL  config/busyyaks.yml\s+Permission denied}, out)
      assert_match(/^ok    ruby\s/, out, "the other rows are still reported")
    end
  end

  def test_doctor_reports_an_unreadable_or_missing_config_as_a_row
    @runner = FakeRunner.new(answers: { %w[docker compose version] => ["2.32.4\n", true] })
    File.write(File.join(@home, "config/busyyaks.yml"), "daily_report_runners: [\n")
    code, out, err = yaks("doctor")
    assert_equal [1, ""], [code, err]
    assert_match(%r{^FAIL  config/busyyaks.yml\s+\(.*\): did not find expected node content}, out)
    assert_match(%r{^ok    docker\s+/usr/bin/docker}, out, "the other rows are still reported")
    refute_match(/^\S+\s+jq\s/, out, "an unreadable config: the daily tools are not asked")
    File.delete(File.join(@home, "config/busyyaks.yml"))
    code, out, = yaks("doctor")
    assert_equal 1, code
    assert_match(%r{^FAIL  config/busyyaks.yml\s+missing: cp config/busyyaks.example.yml config/busyyaks.yml}, out)
    assert_match(/^ok    ruby\s/, out)
  end

  def test_the_real_runner_finds_programs_on_path_and_refuses_the_rest
    runner = CLI::Runner.new({ "PATH" => "/nonexistent:#{File.dirname(RbConfig.ruby)}" })
    assert_equal RbConfig.ruby, runner.which(File.basename(RbConfig.ruby))
    assert_nil runner.which("no-such-program-yaks")
    out, ok = runner.capture(File.basename(RbConfig.ruby), "-e", "print 42")
    assert_equal ["42", true], [out, ok]
    refute runner.capture(File.basename(RbConfig.ruby), "-e", "exit 3").last
    assert runner.system(File.basename(RbConfig.ruby), "-e", "exit 0")
    assert_raises(CLI::Refused) { runner.system("no-such-program-yaks") }
    assert_raises(CLI::Refused) { runner.exec("no-such-program-yaks") }
    assert_raises(CLI::Refused) { CLI::Runner.new({}) }
  end

  def test_http_down_names_the_address
    port = TCPServer.open("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    e = assert_raises(CLI::Http::Down) { CLI::Http.get("127.0.0.1", port, "/up", {}) }
    assert_includes e.message, "127.0.0.1:#{port}:"
  end

  def test_http_answers_with_code_and_body
    server = TCPServer.open("127.0.0.1", 0)
    t = Thread.new do
      2.times do
        c = server.accept
        nil until c.gets == "\r\n"
        c.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        c.close
      end
    end
    assert_equal [200, "ok"], CLI::Http.get("127.0.0.1", server.addr[1], "/up", {})
    assert_equal [200, "ok"], CLI::Http.post("127.0.0.1", server.addr[1], "/mcp", { "Content-Length" => "0" }, "")
  ensure
    t&.join(5)
    server&.close
  end

  # the CI gate that runs the host-side tests uses MIN_RUBY's own version (scripts/ci/test.sh HOST_RUBY_IMAGE)
  def test_the_host_gate_runs_min_ruby
    image = File.read(File.expand_path("../../scripts/ci/test.sh", __dir__))[/^HOST_RUBY_IMAGE=ruby:(\S+)-slim/, 1]
    assert_equal CLI::MIN_RUBY, image.split(".").first(2).join(".")
  end

  # run's default os is uname's sysname: a non-Linux one is refused without passing os:
  def test_the_default_os_is_unames_sysname
    Etc.stub(:uname, { sysname: "Darwin", release: "24.0" }) do
      assert_equal "Darwin", CLI::Host.os
      out = StringIO.new
      err = StringIO.new
      code = CLI.run(["help"], home: @home, env: { "PATH" => "/usr/bin" }, out: out, err: err, runner: @runner)
      assert_equal [1, ""], [code, out.string]
      assert_includes err.string, "this is Darwin"
    end
  end
end
