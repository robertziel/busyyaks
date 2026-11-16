# frozen_string_literal: true

# Standalone (no test_helper, no app), like cli_test.rb: runs on the oldest host Ruby too (scripts/ci/test.sh host).
require "minitest/autorun"
require "base64"
require "fileutils"
require "json"
require "socket"
require "stringio"
require "tmpdir"
require_relative "../../cli/yaks"

# `yaks remote …` and `yaks env --ports` (the desktop chooser: cli_chooser_test.rb): the exact ssh argv,
# every refusal, the --stdio bridge against a fake launcher socket, the attach client's frames.
class CliRemoteTest < Minitest::Test
  CLI = Busyyaks::CLI

  # capture_all answers [out, err, status] for an argv; stream hands the block the given pipes
  class FakeRunner
    attr_reader :calls

    def initialize(answer: nil, stream: nil)
      @answer = answer
      @stream = stream
      @calls = []
    end

    def which(name) = "/usr/bin/#{name}"

    def capture_all(*argv)
      @calls << [:capture_all, argv]
      @answer || raise("no ssh answer set")
    end

    def stream(*argv)
      @calls << [:stream, argv]
      yield(*@stream)
    end

    def exec(*argv) = @calls << [:exec, argv]

    def system(*argv)
      @calls << [:system, argv]
      true
    end
  end

  def setup
    @home = Dir.mktmpdir("yaks-remote")
    @run = File.join(@home, "run")
    FileUtils.mkdir_p([@run, File.join(@home, "public/static")])
    File.write(File.join(@home, "public/static/icon-512.png"), "png")
    File.write(File.join(@home, ".env"), <<~ENV)
      PUBLIC_HOST=
      WEB_HOST_PORT=8080
      MCP_HOST=127.0.0.1
      MCP_HOST_PORT=8081
      MCP_TOKEN=secret-token
      LAUNCHER_RUN_DIR=#{@run}
    ENV
    @runner = FakeRunner.new
  end

  def teardown
    FileUtils.rm_rf(@home)
  end

  def env = { "PATH" => "/usr/bin", "HOME" => @home }
  def remotes = File.join(@home, ".config/busyyaks/remotes.yml")

  def yaks(*argv, stdin: StringIO.new, os: "Linux", environment: env)
    out = StringIO.new
    err = StringIO.new
    code = CLI.run(argv, home: @home, env: environment, out: out, err: err, os: os, ruby: "3.4.1", runner: @runner,
                         stdin: stdin)
    [code, out.string, err.string]
  end

  def ports_answer(web: 9090, mcp: 9091, host: "srv")
    [JSON.generate(host: host, web_port: web, mcp_host: "127.0.0.1", mcp_port: mcp), "", 0]
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1].tap { s.close }
  end

  # --- add / list / remove -----------------------------------------------------------------------------------------

  def test_add_list_remove_saves_per_user_and_connects_to_nothing
    assert_equal [0, "no remote servers saved (yaks remote add TARGET)\n"], yaks("remote", "list").first(2)
    assert_equal 0, yaks("remote", "add", "box").first
    assert_equal 0, yaks("remote", "add", "me@host.example").first
    assert_equal [0, "box\nme@host.example\n"], yaks("remote", "list").first(2)
    assert_equal 0o600, File.stat(remotes).mode & 0o777
    assert_equal({ "remotes" => [{ "target" => "box" }, { "target" => "me@host.example" }] }, YAML.load_file(remotes))
    code, _, err = yaks("remote", "add", "box")
    assert_equal 1, code
    assert_includes err, "box is already saved"
    assert_equal 0, yaks("remote", "remove", "box").first
    assert_equal [0, "me@host.example\n"], yaks("remote", "list").first(2)
    code, _, err = yaks("remote", "remove", "box")
    assert_equal 1, code
    assert_includes err, "box is not saved"
    assert_empty @runner.calls, "add, list and remove run nothing"
  end

  def test_the_file_follows_xdg_config_home
    xdg = File.join(@home, "xdg")
    assert_equal 0, yaks("remote", "add", "box", environment: env.merge("XDG_CONFIG_HOME" => xdg)).first
    assert File.file?(File.join(xdg, "busyyaks/remotes.yml"))
    refute File.exist?(remotes)
  end

  def test_a_target_is_never_an_option_and_a_bad_file_is_refused
    ["-oProxyCommand=touch x", "a b", "box;rm", "@host", ""].each do |t|
      code, _, err = yaks("remote", "add", t)
      assert_equal 1, code, t
      assert_includes err, "is not an ssh target", t
    end
    code, _, err = yaks("remote", "add", "local")
    assert_equal 1, code
    assert_includes err, "\"local\" is reserved (the desktop chooser's Local row)"
    FileUtils.mkdir_p(File.dirname(remotes))
    ["remotes: [{target: '-oX'}]\n", "remotes: [{target: local}]\n"].each do |doc|
      File.write(remotes, doc)
      code, _, err = yaks("remote", "list")
      assert_equal 1, code, doc
      assert_includes err, "not a remotes file", doc
    end
    [%w[remote], %w[remote bogus], %w[remote add], %w[remote add a b], %w[remote list x], %w[remote connect],
     %w[remote attach box], %w[remote --stdio x],].each do |argv|
      assert_equal 2, yaks(*argv).first, argv.inspect
    end
  end

  # --- env --ports / connect -----------------------------------------------------------------------------------------

  def test_env_ports_prints_the_host_and_ports_and_no_token
    code, out, = yaks("env", "--ports")
    assert_equal 0, code
    ports = JSON.parse(out)
    assert_equal({ "web_port" => 8080, "mcp_host" => "127.0.0.1", "mcp_port" => 8081 }, ports.except("host"))
    assert_match(/\A[A-Za-z0-9._-]+\z/, ports["host"])
    refute_includes out, "secret-token"
  end

  def test_connect_forwards_the_servers_own_port
    yaks("remote", "add", "box")
    web = free_port
    @runner = FakeRunner.new(answer: ports_answer(web: web))
    code, out, = yaks("remote", "connect", "box")
    assert_equal 0, code
    assert_includes out, "srv (box): http://127.0.0.1:#{web}/?remote=srv"
    assert_equal [[:capture_all, %w[ssh -T -o BatchMode=yes -o ConnectTimeout=10 box -- yaks env --ports]],
                  [:exec, ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=5", "-o",
                           "ServerAliveCountMax=2", "-L", "127.0.0.1:#{web}:127.0.0.1:#{web}", "box",],],], @runner.calls
  end

  def test_connect_mcp_forwards_it_and_never_prints_the_token
    yaks("remote", "add", "box")
    web = free_port
    mcp = free_port
    @runner = FakeRunner.new(answer: ports_answer(web: web, mcp: mcp))
    code, out, = yaks("remote", "connect", "box", "--mcp")
    assert_equal 0, code
    assert_includes @runner.calls.last[1], "127.0.0.1:#{mcp}:127.0.0.1:#{mcp}"
    assert_includes out, %(claude mcp add --transport http --scope user busyyaks-srv "http://127.0.0.1:#{mcp}/mcp" ) +
                         %(--header "Authorization: Bearer $MCP_TOKEN")
    refute_includes out, "secret-token"
  end

  def test_connect_refusals
    code, _, err = yaks("remote", "connect", "box")
    assert_equal 1, code
    assert_includes err, "box is not a saved server"
    yaks("remote", "add", "box")
    { [ "", "bash: line 1: yaks: command not found", 127] => "box has no busyyaks: `yaks` is not on its PATH",
      ["", "ssh: Could not resolve hostname box", 255] => "ssh box failed (exit 255): ssh: Could not resolve hostname",
      ["nope", "", 0] => "not JSON",
      [JSON.generate(host: "srv", web_port: 0, mcp_host: "127.0.0.1", mcp_port: 1), "", 0] => "not its ports",
      [JSON.generate(host: "srv", web_port: 1, mcp_host: "10.0.0.1", mcp_port: 1), "", 0] => "not its ports", }
      .each do |answer, why|
        @runner = FakeRunner.new(answer: answer)
        code, _, err = yaks("remote", "connect", "box")
        assert_equal 1, code, why
        assert_includes err, why
        assert_equal [:capture_all], @runner.calls.map(&:first), "no forward after a refusal"
      end
  end

  def test_connect_refuses_a_taken_forward_port
    yaks("remote", "add", "box")
    taken = TCPServer.new("127.0.0.1", 0)
    @runner = FakeRunner.new(answer: ports_answer(web: taken.addr[1]))
    code, _, err = yaks("remote", "connect", "box")
    assert_equal 1, code
    assert_includes err, "127.0.0.1:#{taken.addr[1]} is taken on this machine"
    assert_equal [:capture_all], @runner.calls.map(&:first)
  ensure
    taken&.close
  end

  # --- --stdio: ssh's stdin/stdout ↔ the launcher socket ------------------------------------------------------------

  # a launcher that answers the attach op, then echoes each client line back as output
  def fake_launcher
    server = UNIXServer.new(File.join(@run, "launcher.sock"))
    got = []
    thread = Thread.new do
      c = server.accept
      got << c.gets
      c.write("#{JSON.generate(ok: true, session: 's1', cols: 80, rows: 24, screen: '')}\n")
      loop do
        l = c.gets or break
        got << l
        c.write("#{JSON.generate(o: Base64.strict_encode64("echo #{l.strip}"))}\n")
      end
      c.close
    end
    [server, got, thread]
  end

  def test_stdio_bridges_an_attach_to_the_launcher_socket
    server, got, thread = fake_launcher
    r, w = IO.pipe
    w.write(%({"op":"attach","session":"s1","socket":"default"}\n{"control":true}\n))
    w.close
    code, out, = yaks("remote", "--stdio", stdin: r)
    thread.join(5)
    assert_equal 0, code
    assert_equal [%({"op":"attach","session":"s1","socket":"default"}\n), %({"control":true}\n)], got
    lines = out.lines.map { JSON.parse(_1) }
    assert_equal true, lines.first["ok"]
    assert_equal "echo {\"control\":true}", Base64.decode64(lines[1]["o"])
  ensure
    server&.close
  end

  def test_stdio_carries_only_the_allowlisted_ops
    server, got, thread = fake_launcher
    [%({"op":"launch","type":"lead"}\n), "not json\n", "[1]\n", "",
     %({"op":"attach","socket":"default"}\n), %({"op":"attach","session":"s1;x","socket":"default"}\n),
     %({"op":"attach","session":"s1","socket":"../x"}\n), %({"op":"attach","session":"s1","socket":7}\n),].each do |line|
      code, out, err = yaks("remote", "--stdio", stdin: StringIO.new(line))
      assert_equal 1, code, line
      refute JSON.parse(out)["ok"], line
      assert_match(/not carried over ssh|not JSON|a JSON object|no request|not a tmux (session|socket) name/, err)
    end
    assert_empty got, "nothing reached the launcher"
    thread.kill
  ensure
    server&.close
  end

  ATTACH = %({"op":"attach","session":"s1","socket":"default"}\n)

  def test_stdio_needs_the_launcher_socket_and_linux
    code, _, err = yaks("remote", "--stdio", stdin: StringIO.new(ATTACH))
    assert_equal 1, code
    assert_includes err, "no launcher socket at #{@run}/launcher.sock"
    File.write(File.join(@run, "launcher.sock"), "")
    assert_includes yaks("remote", "--stdio", stdin: StringIO.new(ATTACH))[2], "is not a socket"
    assert_includes yaks("remote", "--stdio", os: "Darwin")[2], "busyyaks runs on Linux only"
  end

  # --- attach: the client end ---------------------------------------------------------------------------------------

  def frames(*hashes) = StringIO.new(hashes.map { "#{JSON.generate(_1)}\n" }.join)

  def test_attach_shows_the_screen_and_the_stream_over_ssh
    yaks("remote", "add", "box")
    w = StringIO.new
    r = frames({ ok: true, session: "s1", cols: 80, rows: 24, screen: Base64.strict_encode64("SCREEN") },
               { o: Base64.strict_encode64("more") }, { refused: "nope" }, { exit: "the session is gone" })
    keys, = IO.pipe
    @runner = FakeRunner.new(stream: [w, r])
    code, out, err = yaks("remote", "attach", "box", "s1", stdin: keys)
    assert_equal 0, code
    assert_equal "SCREENmore", out
    assert_includes err, "attached to s1 on box, read-only"
    assert_includes err, "refused: nope"
    assert_includes err, "ended: the session is gone"
    assert_equal [:stream, %w[ssh -T -o ServerAliveInterval=5 -o ServerAliveCountMax=2 box -- yaks remote --stdio]],
                 @runner.calls.last
    assert_equal({ "op" => "attach", "session" => "s1", "socket" => "default" }, JSON.parse(w.string.lines.first))
  end

  def test_attach_refusals
    code, _, err = yaks("remote", "attach", "box", "s1")
    assert_equal [1, true], [code, err.include?("box is not a saved server")]
    yaks("remote", "add", "box")
    assert_includes yaks("remote", "attach", "box", "bad name")[2], "is not a tmux session name"
    @runner = FakeRunner.new(stream: [StringIO.new, frames({ ok: false, error: "session s1 is not running" })])
    code, _, err = yaks("remote", "attach", "box", "s1")
    assert_equal 1, code
    assert_includes err, "box: session s1 is not running"
    @runner = FakeRunner.new(stream: [StringIO.new, StringIO.new])
    assert_includes yaks("remote", "attach", "box", "s1")[2], "the stream ended before an answer"
  end

  # keys go out only in control; Ctrl-] t asks for control (the launcher's {"control"} confirms it); Ctrl-] q detaches
  def test_attach_keys_wait_for_control
    w = StringIO.new
    err = StringIO.new
    ctx = Struct.new(:stdin, :out, :err).new(StringIO.new("a\x1dtb\x1dq"), StringIO.new, err)
    a = CLI::Remote::Attach.new(ctx, w, StringIO.new, "box")
    a.read_keys
    assert_equal [%({"control":true}\n)], w.string.lines
    assert_includes err.string, "read-only: Ctrl-] t takes control first"
    assert_includes err.string, "detached"
    a.frame("control" => true)
    w2 = StringIO.new
    ctx2 = Struct.new(:stdin, :out, :err).new(StringIO.new("x"), StringIO.new, StringIO.new)
    b = CLI::Remote::Attach.new(ctx2, w2, StringIO.new, "box")
    b.frame("control" => true)
    b.read_keys
    assert_equal({ "i" => Base64.strict_encode64("x") }, JSON.parse(w2.string.lines.first))
  end

  # a terminal: keys go raw (no line buffering), so Ctrl-] t / q act at once
  class TtyIn < StringIO
    attr_reader :raws

    def tty? = true

    def raw
      @raws = (@raws || 0) + 1
      yield self
    end
  end

  def test_attach_puts_a_terminal_in_raw_mode
    stdin = TtyIn.new("")
    ctx = Struct.new(:stdin, :out, :err).new(stdin, StringIO.new, StringIO.new)
    hello = frames({ ok: true, session: "s1", cols: 80, rows: 24, screen: Base64.strict_encode64("$ ") })
    assert_equal 0, CLI::Remote::Attach.new(ctx, StringIO.new, hello, "box").run
    assert_equal 1, stdin.raws
    assert_respond_to $stdin, :raw, "io/console is loaded"
  end
end
