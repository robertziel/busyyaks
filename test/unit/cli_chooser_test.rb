# frozen_string_literal: true

# Standalone (no test_helper, no app), like cli_test.rb: runs on the oldest host Ruby too (scripts/ci/test.sh host).
require "minitest/autorun"
require "fileutils"
require "json"
require "net/http"
require "socket"
require "stringio"
require "tmpdir"
require_relative "../../cli/yaks"

# `yaks desktop open`: the desktop app's server chooser — its guards (Host, the one-time launch code, the
# cookie, Origin), Local first, the saved servers' forwards (a fake ssh: a real child + a listener answering /up),
# Add / Remove, one chooser per user, and the end: no window for the grace → every forward stopped.
class CliChooserTest < Minitest::Test
  CLI = Busyyaks::CLI
  ROOT = File.expand_path("../..", __dir__)

  # spawn: the browser → a finished child, its argv kept; the ports probe (ssh … yaks env --ports) → the answer on its
  # out/err pipes and a child that exits with its status after `delay`; the forward (ssh -N) → a sleeping child in its
  # own group, plus (forward:) a listener on the forwarded port that answers /up 200 while the child lives
  class FakeRunner
    attr_reader :windows, :ssh, :pids, :probes

    def initialize(answer: nil, forward: true, delay: 0, spawn_error: nil)
      @answer = answer
      @forward = forward
      @delay = delay
      @spawn_error = spawn_error
      @windows = Queue.new
      @ssh = []
      @pids = []
      @probes = []
    end

    def which(name) = "/usr/bin/#{name}"

    def spawn(*argv, out: File::NULL, err: File::NULL)
      if argv.last == "--ports"
        @ssh << [:probe, argv]
        answer, words, status = @answer || ["", "ssh: Could not resolve hostname", 255]
        out.write(answer)
        err.write(words)
        Process.spawn("sh", "-c", "sleep #{@delay}; exit #{status}", pgroup: true).tap { @probes << _1 }
      elsif argv.first == "ssh"
        @ssh << [:spawn, argv]
        raise @spawn_error if @spawn_error

        err.write("Warning: Permanently added\n") if err.is_a?(IO)
        pid = Process.spawn("sleep", "30", pgroup: true, err: err)
        @pids << pid
        listen(argv) if @forward
        pid
      else
        @windows << argv
        Process.spawn("true")
      end
    end

    def listen(argv)
      port = Integer(argv[argv.index("-L") + 1].split(":")[1])
      srv = TCPServer.new("127.0.0.1", port)
      Thread.new do
        loop do
          c = srv.accept
          c.readpartial(4096)
          c.write("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
          c.close
        end
      rescue IOError
        nil
      end
      (@listeners ||= []) << srv
    end

    def close = @listeners&.each(&:close)
  end

  def setup
    @home = Dir.mktmpdir("yaks-chooser")
    FileUtils.mkdir_p(File.join(@home, "public/static/fonts"))
    FileUtils.cp_r(File.join(ROOT, "skins"), @home)
    File.write(File.join(@home, "public/static/logo-light.svg"), "<svg/>")
    @local = free_port
    File.write(File.join(@home, ".env"), "PUBLIC_HOST=\nWEB_HOST_PORT=#{@local}\n")
    @runner = FakeRunner.new
  end

  def teardown
    @server&.stop!
    @thread&.join(5)
    @runner.close
    FileUtils.rm_rf(@home)
  end

  def env = { "PATH" => "/usr/bin", "HOME" => @home }

  def ctx(out = StringIO.new)
    CLI::Context.new(home: @home, env: env, runner: @runner, out: out, err: StringIO.new, os: "Linux", ruby: "3.4.1",
                     http: nil, stdin: StringIO.new)
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1].tap { s.close }
  end

  def state_dir = File.join(@home, ".local/state/busyyaks")

  # the chooser in a thread, through Chooser.open (it takes the lock); → the first window's URL (the launch link)
  def start(**opts)
    ready = Queue.new
    @thread = Thread.new { @code = CLI::Chooser.open(ctx, "/usr/bin/chromium", tick: 0.1, **opts) { ready << _1 } }
    @server = ready.pop(timeout: 5)
    argv = @runner.windows.pop(timeout: 5)
    assert_equal "/usr/bin/chromium", argv.first
    argv.last.delete_prefix("--app=")
  end

  def http(method, path, headers = {}, body = nil)
    Net::HTTP.start("127.0.0.1", @server.port) do |h|
      req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(path, headers)
      req.body = body if body
      h.request(req)
    end
  end

  def sign_in(url)
    res = http(:get, url.sub(%r{\Ahttp://[^/]+}, ""))
    assert_equal "303", res.code
    res["set-cookie"].split(";").first
  end

  def origin = "http://127.0.0.1:#{@server.port}"

  def api(cookie, path, server)
    res = http(:post, path, { "cookie" => cookie, "origin" => origin, "content-type" => "application/json" },
               JSON.generate(server: server))
    [res.code, JSON.parse(res.body)]
  end

  def first_event(cookie)
    s = TCPSocket.new("127.0.0.1", @server.port)
    s.write("GET /events HTTP/1.1\r\nHost: 127.0.0.1:#{@server.port}\r\nCookie: #{cookie}\r\n\r\n")
    data = nil
    data = s.gets until data&.start_with?("data: ")
    [s, JSON.parse(data.delete_prefix("data: "))]
  end

  # the stream's states until one passes the block (5 s at most) → that state
  def event_until(sock)
    deadline = Time.now + 5
    loop do
      raise "no such state within 5 s" if Time.now > deadline

      line = sock.gets
      next unless line&.start_with?("data: ")

      state = JSON.parse(line.delete_prefix("data: "))
      return state if yield(state)
    end
  end

  # gone, or a zombie (exited, not reaped yet)
  def process_gone?(pid)
    File.read("/proc/#{pid}/stat").split[2] == "Z"
  rescue Errno::ENOENT, Errno::ESRCH
    true
  end

  # --- the guards ----------------------------------------------------------------------------------------------------

  def test_the_page_needs_the_launch_code_once_then_the_cookie
    url = start
    assert_match %r{\Ahttp://127\.0\.0\.1:\d+/\?code=\d+\.\h{32}\.\h{64}\z}, url
    assert_equal "403", http(:get, "/").code, "no cookie, no page"
    cookie = sign_in(url)
    assert_match(/\Ayaks_chooser=\h{64}\z/, cookie)
    page = http(:get, "/", "cookie" => cookie)
    assert_equal "200", page.code
    assert_includes page.body.force_encoding("UTF-8"), "<title>busyyaks · servers</title>"
    assert_includes page["content-security-policy"], "default-src 'none'"
    assert_equal "403", http(:get, url.sub(%r{\Ahttp://[^/]+}, "")).code, "a used launch code is refused"
    assert_equal "403", http(:get, "/", "cookie" => "yaks_chooser=#{'0' * 64}").code
    assert_equal "403", http(:get, "/?code=1.2.3").code
    assert_equal "200", http(:get, "/chooser.js").code, "the assets need no cookie"
    assert_equal "404", http(:get, "/../.env", "cookie" => cookie).code
  end

  def test_host_and_origin_are_checked
    cookie = sign_in(start)
    assert_equal "421", http(:get, "/", "host" => "evil.example:#{@server.port}", "cookie" => cookie).code
    assert_equal "421", http(:get, "/", "host" => "localhost:#{@server.port}", "cookie" => cookie).code
    res = http(:post, "/api/add", { "cookie" => cookie, "origin" => "http://evil.example" }, '{"server":"box"}')
    assert_equal "403", res.code
    res = http(:post, "/api/add", { "cookie" => cookie }, '{"server":"box"}')
    assert_equal "403", res.code, "a POST with no Origin"
    refute File.exist?(File.join(@home, ".config/busyyaks/remotes.yml")), "nothing saved"
    assert_equal "400", http(:post, "/api/add", { "cookie" => cookie, "origin" => origin }, "nope").code
  end

  def test_the_state_file_is_this_users_only
    start
    assert_equal 0o700, File.stat(state_dir).mode & 0o777
    path = File.join(state_dir, "desktop.json")
    assert_equal 0o600, File.stat(path).mode & 0o777
    doc = JSON.parse(File.read(path))
    assert_equal [Process.pid, @server.port], [doc["pid"], doc["port"]]
    File.chmod(0o755, state_dir)
    err = assert_raises(CLI::Refused) { CLI::Chooser.state_dir(ctx) }
    assert_includes err.message, "is open to others (mode 755)"
  end

  # --- Local, the saved servers ----------------------------------------------------------------------------------

  def test_local_comes_first_and_opens_a_window_on_this_checkouts_dashboard
    up = TCPServer.new("127.0.0.1", @local)
    Thread.new do
      loop do
        c = up.accept
        c.readpartial(4096)
        c.write("HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        c.close
      end
    rescue IOError
      nil
    end
    cookie = sign_in(start)
    s, = first_event(cookie)
    state = event_until(s) { _1["local"]["state"] == "up" }
    assert_equal({ "url" => "http://127.0.0.1:#{@local}", "state" => "up", "detail" => nil }, state["local"])
    assert_equal [], state["servers"]
    assert_equal "200", api(cookie, "/api/open", "local").first
    assert_equal ["/usr/bin/chromium", "--app=http://127.0.0.1:#{@local}"], @runner.windows.pop(timeout: 5)
  ensure
    s&.close
    up&.close
  end

  def test_no_local_stack_says_why_and_still_lists_the_servers
    FileUtils.rm_f(File.join(@home, ".env"))
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start)
    s, = first_event(cookie)
    state = event_until(s) { _1["local"]["state"] == "none" }
    assert_includes state["local"]["detail"], ".env"
    assert_equal [{ "target" => "box", "state" => "idle", "detail" => nil, "host" => nil, "url" => nil }], state["servers"]
    code, body = api(cookie, "/api/open", "local")
    assert_equal "422", code
    assert_includes body["error"], "no local busyyaks here"
  ensure
    s&.close
  end

  def test_add_and_remove_go_through_the_saved_servers_file
    cookie = sign_in(start)
    code, body = api(cookie, "/api/add", "me@box.example")
    assert_equal "200", code
    assert_equal ["me@box.example"], body["servers"].map { _1["target"] }
    assert_equal ["me@box.example"], CLI::Remote.saved(ctx)
    assert_equal "422", api(cookie, "/api/add", "me@box.example").first
    code, body = api(cookie, "/api/add", "-oProxyCommand=x")
    assert_equal "422", code
    assert_includes body["error"], "is not an ssh target"
    code, body = api(cookie, "/api/remove", "me@box.example")
    assert_equal ["200", []], [code, body["servers"]]
    assert_equal [], CLI::Remote.saved(ctx)
  end

  def test_connect_forwards_the_servers_port_then_opens_its_window_and_disconnect_stops_ssh
    web = free_port
    @runner = FakeRunner.new(answer: [JSON.generate(host: "srv", web_port: web, mcp_host: "127.0.0.1", mcp_port: 1), "", 0])
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start)
    assert_equal "200", api(cookie, "/api/open", "box").first
    assert_equal ["/usr/bin/chromium", "--app=http://127.0.0.1:#{web}/?remote=srv"], @runner.windows.pop(timeout: 5)
    spawn = @runner.ssh.find { _1.first == :spawn }.last
    assert_equal ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                  "-o", "ServerAliveInterval=5",
                  "-o", "ServerAliveCountMax=2", "-L", "127.0.0.1:#{web}:127.0.0.1:#{web}", "box",], spawn
    code, body = api(cookie, "/api/open", "box")
    assert_equal "200", code, "a connected server: another window, no second forward"
    assert_equal 1, @runner.ssh.count { _1.first == :spawn }
    assert_equal({ "target" => "box", "state" => "connected", "detail" => nil, "host" => "srv",
                   "url" => "http://127.0.0.1:#{web}/?remote=srv", }, body["servers"].first)
    code, body = api(cookie, "/api/disconnect", "box")
    assert_equal %w[200 idle], [code, body["servers"].first["state"]]
    assert_equal "422", api(cookie, "/api/disconnect", "box").first
  end

  def test_a_failed_connect_shows_sshs_reason
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start)
    assert_equal "200", api(cookie, "/api/open", "box").first
    s, = first_event(cookie)
    failed = event_until(s) { _1["servers"].first["state"] == "failed" }["servers"].first
    assert_includes failed["detail"], "ssh box failed (exit 255): ssh: Could not resolve hostname"
    assert @runner.windows.empty?, "no window for a server that is not there"
    assert_equal "422", api(cookie, "/api/open", "other").first, "only a saved server"
  ensure
    s&.close
  end

  def test_a_forward_that_never_answers_is_stopped_and_says_so
    web = free_port
    @runner = FakeRunner.new(answer: [JSON.generate(host: "srv", web_port: web, mcp_host: "127.0.0.1", mcp_port: 1), "", 0],
                             forward: false)
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start(ready: 0.5))
    api(cookie, "/api/open", "box")
    s, = first_event(cookie)
    failed = event_until(s) { _1["servers"].first["state"] == "failed" }["servers"].first
    assert_includes failed["detail"], "/up did not answer 200 within 0.5 s"
  ensure
    s&.close
  end

  # --- one chooser, and its end ----------------------------------------------------------------------------------

  def ports_json(web) = [JSON.generate(host: "srv", web_port: web, mcp_host: "127.0.0.1", mcp_port: 1), "", 0]

  # Disconnect while the server is still asked its ports: no ssh started, no window, nothing left running
  def test_disconnect_during_connect_starts_nothing
    @runner = FakeRunner.new(answer: ports_json(free_port), delay: 30)
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start)
    assert_equal "200", api(cookie, "/api/open", "box").first
    code, body = api(cookie, "/api/disconnect", "box")
    assert_equal %w[200 idle], [code, body["servers"].first["state"]]
    sleep 1
    # the Disconnect may land before the probe starts (then none) or while it runs (then it is stopped)
    assert_empty @runner.ssh.map(&:first) - [:probe], "no ssh forward spawned"
    assert_nil @runner.windows.pop(timeout: 0.2), "no window"
    assert(@runner.probes.all? { process_gone?(_1) }, "the ports probe was stopped with it")
  end

  # the chooser's end stops a probe still waiting on an unreachable server
  def test_the_end_stops_a_probe_in_flight
    @runner = FakeRunner.new(answer: ports_json(free_port), delay: 30)
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start(grace: 0.3))
    s, = first_event(cookie)
    api(cookie, "/api/open", "box")
    s.close
    assert @thread.join(5), "the chooser ended"
    deadline = Time.now + 5
    sleep 0.05 until process_gone?(@runner.probes.first) || Time.now > deadline
    assert process_gone?(@runner.probes.first), "no probe outlives the chooser"
  end

  def test_a_spawn_error_fails_the_row_with_its_reason
    @runner = FakeRunner.new(answer: ports_json(free_port), spawn_error: Errno::EAGAIN)
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start)
    api(cookie, "/api/open", "box")
    s, = first_event(cookie)
    failed = event_until(s) { _1["servers"].first["state"] == "failed" }["servers"].first
    assert_equal "Errno::EAGAIN: Resource temporarily unavailable", failed["detail"]
    assert_equal "200", api(cookie, "/api/open", "box").first, "Connect works again"
  ensure
    s&.close
  end

  # the lock, not the state file, decides: two opens at once → one chooser; a holder that never records → refused
  def test_two_opens_at_once_make_one_chooser
    out = StringIO.new
    threads = Array.new(2) { Thread.new { CLI::Chooser.open(ctx(out), "/usr/bin/chromium", tick: 0.1, first_window: 1) } }
    ports = Array.new(2) { @runner.windows.pop(timeout: 5).last[%r{127\.0\.0\.1:(\d+)/}, 1] }
    assert_equal 1, ports.uniq.size, "both windows on the one chooser"
    threads.each { assert _1.join(5) } # each prints its line after its window: count once both are done
    assert_equal 1, out.string.scan("chooser on http").size
    assert_equal 1, out.string.scan("the chooser runs already").size
  end

  def test_a_lock_holder_that_records_nothing_is_refused
    dir = CLI::Chooser.state_dir(ctx)
    File.open(File.join(dir, "desktop.lock"), File::RDWR | File::CREAT, 0o600) do |held|
      held.flock(File::LOCK_EX)
      out = StringIO.new
      err = assert_raises(CLI::Refused) { CLI::Chooser.open(ctx(out), "/usr/bin/chromium", wait: 0.3) }
      assert_includes err.message, "holds #{dir}/desktop.lock but answers on no recorded port after 0.3 s"
    end
  end

  def test_a_second_open_only_opens_another_window_on_the_running_chooser
    start
    out = StringIO.new
    assert_equal 0, CLI::Chooser.open(ctx(out), "/usr/bin/chromium")
    assert_includes out.string, "the chooser runs already (pid #{Process.pid})"
    second = @runner.windows.pop(timeout: 5).last.delete_prefix("--app=")
    assert_match %r{\Ahttp://127\.0\.0\.1:#{@server.port}/\?code=}, second
    sign_in(second)
  end

  def test_it_ends_after_its_last_window_and_stops_every_forward
    web = free_port
    @runner = FakeRunner.new(answer: [JSON.generate(host: "srv", web_port: web, mcp_host: "127.0.0.1", mcp_port: 1), "", 0])
    CLI::Remote.add!(ctx, "box")
    cookie = sign_in(start(grace: 0.3))
    s, = first_event(cookie)
    api(cookie, "/api/open", "box")
    @runner.windows.pop(timeout: 5)
    assert File.exist?(File.join(state_dir, "desktop.json"))
    s.close
    assert @thread.join(5), "the chooser ended"
    assert_equal 0, @code
    refute File.exist?(File.join(state_dir, "desktop.json")), "its state file is gone"
    pid = @runner.pids.first
    deadline = Time.now + 5
    sleep 0.05 until process_gone?(pid) || Time.now > deadline
    assert process_gone?(pid), "the forward's ssh was stopped"
  end

  # a window that opens and closes between two of the chooser's checks still counts: it ends after the grace, not
  # after the first-window wait
  def test_a_window_that_comes_and_goes_at_once_still_counts
    cookie = sign_in(start(grace: 0.3))
    s, = first_event(cookie)
    s.close
    assert @thread.join(5), "ended after the grace (first_window is #{CLI::Chooser::FIRST_WINDOW} s)"
  end

  def test_no_window_ever_arriving_ends_it_too
    start(first_window: 0.3)
    assert @thread.join(5)
  end

  def test_skin_css_reads_the_base_skins_and_refuses_a_value_that_is_not_a_colour
    css = CLI::Chooser.skin_css(@home)
    assert_includes css, ":root {\n  color-scheme: light;\n  --bg: #f4f3ee;"
    assert_includes css, "@media (prefers-color-scheme: dark) {\n  :root {\n    color-scheme: dark;\n    --bg: #0f1115;"
    File.write(File.join(@home, "skins/dark.yml"), "tokens:\n  \"--bg\": \"red;} body{x\"\n")
    assert_raises(CLI::Refused) { CLI::Chooser.skin_css(@home) }
  end

  def test_desktop_open_needs_a_known_browser
    out = StringIO.new
    err = StringIO.new
    code = CLI.run(%w[desktop open --browser /bin/sh], home: @home, env: env, out: out, err: err, os: "Linux",
                                                       ruby: "3.4.1", runner: @runner)
    assert_equal 1, code
    assert_includes err.string, "--browser /bin/sh: not an executable Chromium-family browser"
  end
end
