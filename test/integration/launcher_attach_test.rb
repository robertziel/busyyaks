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
# into it (so any byte written into the CLIENT shows); `send-keys` records its argv (the keys typed into the PANE).
#   - refused: a bad name (400), a session not running (404), a session with no agent in its pane (403);
#   - the first line: the window's size + the pane now (capture-pane), then the client's output as {"o"};
#   - keys are refused until control is taken, then typed into the pane with `copy-mode -q ; send-keys -H <hex>` (any
#     mode cancelled in the same command: a mode's key table would take them; every byte as typed), refused again after
#     release; the tmux client never gets a byte (its key tables — the prefix, `:` + run-shell — are never reached);
#   - a frame that is not one of the protocol's: refused with why; a send tmux refuses: its error.
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
        has-session) [ -e #{b}/gone ] && exit 1; [ "$t" = agent_s ] || [ "$t" = plain_s ]; exit $? ;;
        display-message)
          case "$*" in
            *pane_pid*) [ "$t" = agent_s ] && echo #{@agent} || echo #{@plain} ;;
            *window_width*) cat #{b}/size 2>/dev/null || echo "80 23 on" ;;
          esac; exit 0 ;;
        capture-pane) printf 'SCREEN\\nline2\\n'; exit 0 ;;
        attach-session)
          : > #{b}/typed; tty > #{b}/client_tty; echo "$t" > #{b}/client_session
          # "chatty": a session that redraws all the time (its checks must still run)
          # once tmux "moved" the client (moves), what it draws is ANOTHER session's screen
          [ -e #{b}/chatty ] && ( while [ -e #{b}/chatty ]; do
            if [ -e #{b}/moves ]; then printf 'OTHER-SESSION\\r\\n'; else printf 'tick\\r\\n'; fi; sleep 0.1; done ) &
          printf 'DRAWN\\r\\n'
          while IFS= read -r l; do echo "$l" >> #{b}/typed; printf 'typed:%s\\r\\n' "$l"; done; exit 0 ;;
        copy-mode)
          # `copy-mode -q -t T ; send-keys …` (one command): the mode cancel recorded, the keys after it as before
          [ "$2" = -q ] && [ "$5" = ";" ] && [ "$6" = send-keys ] || { echo "copy-mode without the send: $*" >&2; exit 1; }
          echo "cancel $4" >> #{b}/modes
          [ -e #{b}/pane_gone ] && { echo "can't find pane: $t" >&2; exit 1; }
          # the whole line in one write (the test reads the file while this runs)
          shift 6; l=""; for a; do l="$l[$a]"; done; printf '%s\\n' "$l" >> #{b}/sent; exit 0 ;;
        send-keys) echo "send-keys without the mode cancel: $*" >&2; exit 1 ;;
        list-clients)
          [ -e #{b}/moves ] && echo lead_s > #{b}/client_session
          printf '%s %s\\n' "$(cat #{b}/client_tty)" "$(cat #{b}/client_session)"; exit 0 ;;
        detach-client) echo detached > #{b}/client_session; exit 0 ;;
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

  # the keys each send-keys typed: its argv is -t =agent_s: -H <one hex byte per argument>, decoded back to the bytes
  def sent
    path = File.join(@base, "sent")
    return [] unless File.exist?(path)

    # complete lines only: a send still being written is not counted yet
    File.read(path).split("\n", -1)[0...-1].map do |l|
      args = l.scan(/\[([^\]]*)\]/).flatten
      assert_equal ["-t", "=agent_s:", "-H"], args.first(3), l
      args.drop(3).map { |h| h.to_i(16) }.pack("C*")
    end
  end
  def typed = File.read(File.join(@base, "typed"))
  def await_sent(n)
    Timeout.timeout(10) { sleep 0.05 until sent.size >= n }
    sent
  end
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

  def test_screen_then_keys_into_the_pane_only_in_control
    s, hello = connect("op" => "attach", "session" => "agent_s")
    assert_equal [true, "agent_s", 80, 24], hello.values_at("ok", "session", "cols", "rows"), hello.inspect
    assert_equal "SCREEN\r\nline2\r\n", Base64.decode64(hello["screen"])
    seen = []
    await(s, seen) { output(seen).include?("DRAWN") }
    assert_match(/attach-session -f ignore-size,read-only -t =agent_s/, File.read(File.join(@base, "tmux.log")))

    keys(s, "early\r")
    assert_equal({ "refused" => "input while not in control: nothing typed" }, await(s) { |f| f["refused"] })
    send_frame(s, "control" => true)
    assert_equal({ "control" => true }, await(s) { |f| f.key?("control") })
    keys(s, "hello\r")
    keys(s, "-x")
    assert_equal ["hello\r", "-x"], await_sent(2)

    send_frame(s, "control" => false)
    assert_equal({ "control" => false }, await(s) { |f| f.key?("control") })
    keys(s, "late\r")
    assert_equal "input while not in control: nothing typed", await(s) { |f| f["refused"] }["refused"]
    send_frame(s, "x" => 1)
    assert_match(/unknown frame "x"/, await(s) { |f| f["refused"] }["refused"])
    s.puts("not json")
    assert_match(/bad frame/, await(s) { |f| f["refused"] }["refused"])
    s.close
    Timeout.timeout(10) { sleep 0.1 until File.read(@log).include?("attach agent_s: closed") }
    assert_equal 2, sent.size, "nothing typed before control or after release"
    assert_equal "", typed, "the tmux client never got a byte"
    log = File.read(@log)
    ["opened", "control taken", "control released", "closed"].each { |w| assert_match(/attach agent_s: #{w}/, log) }
  end

  # a key written into a tmux CLIENT goes through its key tables — the prefix + c (a host shell), + s (another
  # session), + : run-shell. In control, the prefix and a command line are bytes for the pane,
  # the client is never switched or made writable, and no tmux call acts relative to the launcher's own $TMUX.
  def test_tmux_prefix_keys_are_text_for_the_pane_never_a_client_command
    s, = connect("op" => "attach", "session" => "agent_s")
    await(s) { |f| f["o"] }
    send_frame(s, "control" => true)
    await(s) { |f| f.key?("control") }
    keys(s, "\x02c\x02:run-shell id\r")
    assert_equal ["\x02c\x02:run-shell id\r".b], await_sent(1)
    assert_equal ["cancel =agent_s:"], File.readlines(File.join(@base, "modes"), chomp: true), "the pane's mode cancelled first"
    s.close
    Timeout.timeout(10) { sleep 0.1 until File.read(@log).include?("attach agent_s: closed") }
    assert_equal "", typed, "the tmux client never got a byte"
    log = File.read(File.join(@base, "tmux.log"))
    refute_match(/^(switch-client|refresh-client|new-window|run-shell|command-prompt)/, log)
    assert_equal ["TMUX=unset"], File.readlines(File.join(@base, "tmux.env"), chomp: true).uniq, "tmux never saw $TMUX"
  end

  # every byte goes as typed: a trailing ";" (tmux's command separator: `-l` dropped it silently), a NUL, bytes that
  # are not UTF-8; a send tmux refuses comes back with its error
  def test_any_byte_is_typed_as_it_is
    s, = connect("op" => "attach", "session" => "agent_s")
    await(s) { |f| f["o"] }
    send_frame(s, "control" => true)
    await(s) { |f| f.key?("control") }
    [";", "x;", "\\;", "a\0b", "\xff".b, "é"].each { |k| keys(s, k) }
    assert_equal [";", "x;", "\\;", "a\0b", "\xff", "é"].map(&:b), await_sent(6)
    FileUtils.touch(File.join(@base, "pane_gone"))
    keys(s, "x")
    assert_equal "tmux send-keys failed after 0 of 1 bytes: can't find pane: agent_s",
                 await(s) { |f| f["refused"] }["refused"]
    s.close
  end

  # tmux refuses a command over 16 KB: a paste goes in 4 KB pieces, in order, each with its own mode cancel
  def test_a_long_paste_goes_in_ordered_pieces
    s, = connect("op" => "attach", "session" => "agent_s")
    await(s) { |f| f["o"] }
    send_frame(s, "control" => true)
    await(s) { |f| f.key?("control") }
    paste = Array.new(10_000) { |i| (i % 251).chr }.join.b
    keys(s, paste)
    pieces = await_sent(3)
    assert_equal [4096, 4096, 1808], pieces.map(&:bytesize)
    assert_equal paste, pieces.join
    assert_equal 3, File.readlines(File.join(@base, "modes")).size, "a mode cancel before each piece"
    s.close
  end

  # the session ended and tmux moved our read-only client onto another one: that session is never streamed
  def test_a_client_moved_to_another_session_ends_the_stream
    FileUtils.touch(File.join(@base, "chatty")) # that session redraws all the time: the check runs anyway
    s, = connect("op" => "attach", "session" => "agent_s")
    seen = []
    await(s, seen) { output(seen).include?("tick") }
    FileUtils.touch(File.join(@base, "moves"))
    assert_match(/the tmux client ended/, await(s, seen) { |f| f["exit"] }["exit"])
    refute_includes output(seen), "OTHER-SESSION", "not one byte of the session tmux moved the client to"
    assert_nil s.gets, "the launcher's side of the stream ended (the web then closes it)"
    s.close
    Timeout.timeout(10) { sleep 0.1 until File.read(@log).include?("attach agent_s: closed") }
    assert_match(/attach agent_s: the client showed "lead_s", detached/, File.read(@log))
    assert_match(/detach-client -t \S+/, File.read(File.join(@base, "tmux.log")))
  end

  # taking control re-checks the session (it may have ended, or its agent exited, since the attach)
  def test_control_refused_when_the_session_is_gone
    s, = connect("op" => "attach", "session" => "agent_s")
    await(s) { |f| f["o"] }
    FileUtils.touch(File.join(@base, "gone"))
    send_frame(s, "control" => true)
    assert_equal "session agent_s is not running: control stays off", await(s) { |f| f["refused"] }["refused"]
    keys(s, "x\r")
    assert_equal "input while not in control: nothing typed", await(s) { |f| f["refused"] }["refused"]
    s.close
    assert_empty sent
  end

  def test_a_resized_window_is_sent
    s, = connect("op" => "attach", "session" => "agent_s")
    File.write(File.join(@base, "size"), "100 30 off\n")
    assert_equal({ "cols" => 100, "rows" => 30 }, await(s) { |f| f["size"] }["size"])
    s.close
  end
end
