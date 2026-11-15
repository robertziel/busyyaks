# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "socket"
require "json"
require "etc"
require "yaml"
require "base64"
require "timeout"

# bin/launcher's `attach` op, the launcher itself run as a process in a sandbox checkout with a stub tmux:
# the tmux CLIENT it spawns in a PTY is the stub's `attach-session`, which prints a screen and echoes each line typed
# into it; `switch-client -r`, `refresh-client -f` and `list-clients` keep the client's flags in a file.
#   - refused: a bad name (400), a session not running (404), a session with no agent in its pane (403);
#   - the first line: the window's size + the pane now (capture-pane), then the client's output as {"o"};
#   - keys are refused until control is taken (nothing reaches the client), typed once tmux confirms control,
#     refused again after release; a frame that is not one of the protocol's is refused with why.
class LauncherAttachTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60
  COPY = %w[bin/launcher lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml].freeze
  INVOCATIONS = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands")

  def setup
    @base = File.realpath(Dir.mktmpdir("launcher-attach", Etc.getpwuid(Process.uid).dir))
    @co = File.join(@base, "checkout")
    @bin = File.join(@base, "bin")
    FileUtils.mkdir_p([File.join(@base, "projects"), @bin, File.join(@co, "config"), File.join(@base, "sessions")])
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@co, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@co, f))
    end
    FileUtils.cp(File.join(ROOT, "test/fixtures/kanban.yml"), File.join(@co, "config/kanban.yml"))
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" }, "agents" => { "collector" => "none" },
      "dictation" => "none", "terminal" => { "public_host" => "deny", "max_open" => 4 },
      "launch" => { "trusted_paths" => [], "commands" => INVOCATIONS, "start_seconds" => 30 }
    ))
    File.write(File.join(@co, ".env"), <<~ENV)
      PROJECTS_ROOT=#{File.join(@base, 'projects')}
      PROJECTS_MOUNT=/projects
      LAUNCHER_RUN_DIR=#{File.join(@base, 'run')}
      LAUNCHER_STATE_DIR=#{File.join(@base, 'state')}
      CLAUDE_SESSIONS_DIR=#{File.join(@base, 'sessions')}
      CLAUDE_SESSION_URL=https://claude.example/{id}
    ENV
    # the agent: a copy of bash named claude (so /proc shows that argv); a plain sleep is a pane with no agent
    FileUtils.cp(Open3.capture2("sh", "-c", "command -v bash").first.strip, File.join(@bin, "claude"))
    @agent = Process.spawn(File.join(@bin, "claude"), "-c", "sleep 300; :", %i[out err] => File::NULL)
    @plain = Process.spawn("sleep", "300")
    b = @base
    stub("tmux", <<~SH)
      echo "$*" >> #{b}/tmux.log
      echo "TMUX=${TMUX:-unset}" >> #{b}/tmux.env
      t=""; for a; do case "$a" in =*) t=${a#=}; t=${t%:} ;; esac; done
      case "$1" in
        has-session) [ "$t" = agent_s ] || [ "$t" = plain_s ]; exit $? ;;
        display-message)
          case "$*" in
            *pane_pid*) [ "$t" = agent_s ] && echo #{@agent} || echo #{@plain} ;;
            *window_width*) cat #{b}/size 2>/dev/null || echo "80 23 on" ;;
          esac; exit 0 ;;
        capture-pane) printf 'SCREEN\\nline2\\n'; exit 0 ;;
        attach-session)
          : > #{b}/typed; tty > #{b}/client_tty; echo "$t" > #{b}/client_session; echo attached,ignore-size,read-only > #{b}/flags
          printf 'DRAWN\\r\\n'
          while IFS= read -r l; do echo "$l" >> #{b}/typed; printf 'typed:%s\\r\\n' "$l"; done; exit 0 ;;
        list-clients) printf '%s %s %s\\n' "$(cat #{b}/client_tty)" "$(cat #{b}/client_session)" "$(cat #{b}/flags)"; exit 0 ;;
        detach-client) echo detached > #{b}/client_session; exit 0 ;;
        switch-client)
          # tmux: no -t = the session of $TMUX (the pane the launcher was started from); "moves" = a tmux that
          # switches the client elsewhere whatever it is told
          if [ -z "$t" ] && [ -n "$TMUX" ] || [ -e #{b}/moves ]; then echo lead_s > #{b}/client_session; fi
          [ -e #{b}/stuck ] && exit 0
          case "$(cat #{b}/flags)" in *read-only*) echo attached > #{b}/flags ;; *) echo attached,ignore-size,read-only > #{b}/flags ;; esac
          exit 0 ;;
        refresh-client)
          [ -e #{b}/stuck ] && exit 0
          f=$(cat #{b}/flags); case "$*" in *read-only*) echo "$f,read-only" > #{b}/flags ;; *ignore-size*) echo "$f,ignore-size" > #{b}/flags ;; esac
          exit 0 ;;
      esac
      exit 1
    SH
    start
  end

  def teardown
    [@agent, @plain].each { |p| Process.kill("TERM", p) rescue nil }
    Process.kill("TERM", @pid) if @pid
    Process.wait(@pid) if @pid
    FileUtils.rm_rf(@base)
  end

  def stub(name, body)
    File.write(File.join(@bin, name), "#!/bin/sh\n#{body}")
    File.chmod(0o755, File.join(@bin, name))
  end

  def start
    @log = File.join(@base, "launcher.log")
    # started from inside a tmux pane (TMUX set), as a launcher run by hand is: no tmux call may act relative to it
    env = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "TMUX" => "/tmp/tmux-1/default,1,0", "TMUX_PANE" => "%0" }
    @pid = Process.spawn(env, RbConfig.ruby, File.join(@co, "bin/launcher"),
                         %i[out err] => [@log, "w"])
    sock = File.join(@base, "run/launcher.sock")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_SECONDS
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      return if File.socket?(sock) && (UNIXSocket.open(sock) { true } rescue false)
      flunk "the launcher exited: #{File.read(@log)}" if Process.waitpid(@pid, Process::WNOHANG)

      sleep 0.1
    end
    flunk "no socket after #{BOOT_SECONDS}s: #{File.read(@log)}"
  end

  def connect(req)
    s = UNIXSocket.new(File.join(@base, "run/launcher.sock"))
    s.puts(JSON.generate(req))
    [s, JSON.parse(s.gets)]
  end

  # the next frame (JSON) the stream sends that matches, within a few seconds; the ones before it are collected
  def await(s, seen = [])
    Timeout.timeout(10) do
      loop do
        line = s.gets or flunk "the stream ended; frames: #{seen.inspect}"
        f = JSON.parse(line)
        seen << f
        return f if yield(f)
      end
    end
  end

  def flags = File.read(File.join(@base, "flags")).strip
  def output(seen) = seen.filter_map { |f| f["o"] && Base64.decode64(f["o"]) }.join
  def send_frame(s, h) = s.puts(JSON.generate(h))
  def keys(s, text) = send_frame(s, "i" => Base64.strict_encode64(text))

  def test_refusals_before_anything_is_attached
    { { "session" => "a b" } => 400, { "session" => "gone_s" } => 404, { "session" => "plain_s" } => 403 }.each do |req, st|
      s, r = connect(req.merge("op" => "attach"))
      assert_equal [false, st], r.values_at("ok", "status"), "#{req}: #{r}"
      assert_nil s.gets, "a refusal closes the connection"
      s.close
    end
    refute_match(/attach-session/, File.read(File.join(@base, "tmux.log")), "no tmux client was started")
  end

  def test_screen_then_output_keys_only_in_control
    s, hello = connect("op" => "attach", "session" => "agent_s")
    assert_equal [true, "agent_s", 80, 24], hello.values_at("ok", "session", "cols", "rows"), hello.inspect
    assert_equal "SCREEN\r\nline2\r\n", Base64.decode64(hello["screen"])
    seen = []
    await(s, seen) { output(seen).include?("DRAWN") }
    assert_match(/attach-session -f ignore-size,read-only -t =agent_s/, File.read(File.join(@base, "tmux.log")))

    keys(s, "early\n")
    assert_equal({ "refused" => "input while not in control: nothing typed" }, await(s) { |f| f["refused"] })
    send_frame(s, "control" => true)
    assert_equal({ "control" => true }, await(s) { |f| f.key?("control") })
    assert_equal "attached,ignore-size", flags, "tmux was told: not read-only, still ignore-size"
    keys(s, "hello\n")
    await(s, seen) { output(seen).include?("typed:hello") }
    refute_includes output(seen), "typed:early", "nothing typed before control"

    send_frame(s, "control" => false)
    assert_equal({ "control" => false }, await(s) { |f| f.key?("control") })
    assert_equal "attached,ignore-size,read-only", flags
    keys(s, "late\n")
    assert_equal "input while not in control: nothing typed", await(s) { |f| f["refused"] }["refused"]
    send_frame(s, "x" => 1)
    assert_match(/unknown frame "x"/, await(s) { |f| f["refused"] }["refused"])
    s.puts("not json")
    assert_match(/bad frame/, await(s) { |f| f["refused"] }["refused"])
    s.close
    Timeout.timeout(10) { sleep 0.1 until File.read(@log).include?("attach agent_s: closed") }
    log = File.read(@log)
    ["opened", "control taken", "control released", "closed"].each { |w| assert_match(/attach agent_s: #{w}/, log) }
  end

  # found in QA: a launcher started from a pane typed the viewer's keys into THAT pane's session (switch-client with no
  # -t resolved $TMUX). Every tmux call runs without $TMUX, switch-client names the session, and a client found on
  # another session is detached before any key: the stream ends, nothing typed.
  def test_keys_never_reach_another_session
    s, = connect("op" => "attach", "session" => "agent_s")
    await(s) { |f| f["o"] }
    send_frame(s, "control" => true)
    assert_equal({ "control" => true }, await(s) { |f| f.key?("control") })
    log = File.read(File.join(@base, "tmux.log"))
    assert_match(/^switch-client -c \S+ -t =agent_s -r$/, log)
    assert_equal ["TMUX=unset"], File.readlines(File.join(@base, "tmux.env"), chomp: true).uniq, "tmux never saw $TMUX"
    s.close

    FileUtils.touch(File.join(@base, "moves"))
    s, = connect("op" => "attach", "session" => "agent_s")
    seen = []
    await(s, seen) { |f| f["o"] }
    send_frame(s, "control" => true)
    keys(s, "stray\n")
    # the stream ends: EOF, or a reset when the launcher closes with our unread "stray" still in its buffer
    Timeout.timeout(10) do
      seen << JSON.parse(s.gets) until s.eof?
    rescue Errno::ECONNRESET
      nil
    end
    refute(seen.any? { |f| f["control"] == true }, "control never confirmed: #{seen.inspect}")
    refute_includes output(seen), "typed:stray"
    refute_includes File.read(File.join(@base, "typed")), "stray", "the tmux client got no key"
    assert_match(/detach-client -t \S+/, File.read(File.join(@base, "tmux.log")))
    Timeout.timeout(10) { sleep 0.1 until File.read(@log).include?("attach agent_s: closed") }
    assert_match(/attach agent_s: refused — the client showed "lead_s", detached/, File.read(@log))
    s.close
  end

  def test_control_refused_when_tmux_does_not_confirm_it
    FileUtils.touch(File.join(@base, "stuck"))
    s, = connect("op" => "attach", "session" => "agent_s")
    await(s) { |f| f["o"] }
    send_frame(s, "control" => true)
    assert_match(/did not change the client's read-only flag: control stays off/, await(s) { |f| f["refused"] }["refused"])
    keys(s, "x\n")
    assert_equal "input while not in control: nothing typed", await(s) { |f| f["refused"] }["refused"]
    s.close
  end

  def test_a_resized_window_is_sent
    s, = connect("op" => "attach", "session" => "agent_s")
    File.write(File.join(@base, "size"), "100 30 off\n")
    assert_equal({ "cols" => 100, "rows" => 30 }, await(s) { |f| f["size"] }["size"])
    s.close
  end
end
