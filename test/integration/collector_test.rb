# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/wait"
require "tmpdir"
require "fileutils"
require "open3"
require "socket"
require "json"
require "etc"
require "yaml"

# The contract (card #479): bin/collector writes the snapshot and serves the read socket; bin/launcher — the real one,
# unchanged — reads them. Both run as processes in a sandbox checkout, on the REAL /proc (the agent is a copy of bash
# named claude, so its comm is `claude`) and a stub tmux that answers list-panes with that process's pane and records
# every input. Asserted through the launcher's own ops:
#   - `agents`: the session with its pane, the engine label, the Claude Code record's status / title, its screen state;
#   - `notify`: the launcher's ping reaches the pane as ONE bracketed paste of the text through stdin, then Enter;
#   - `agent_tasks`: refused with the collector's reason.
class CollectorContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60
  COPY = %w[bin/launcher bin/collector lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml].freeze
  INVOCATIONS = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands")

  def setup
    @base = File.realpath(Dir.mktmpdir("collector-contract", Etc.getpwuid(Process.uid).dir))
    @co = File.join(@base, "checkout")
    @bin = File.join(@base, "bin")
    @coll = File.join(@base, "collector")
    tmux_dir = File.join(@base, "tmuxtmp", "tmux-#{Process.uid}")
    FileUtils.mkdir_p([File.join(@base, "projects/app"), @bin, File.join(@co, "config"), File.join(@base, "sessions")])
    FileUtils.mkdir_p(tmux_dir, mode: 0o700)
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@co, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@co, f))
    end
    FileUtils.cp(File.join(ROOT, "test/fixtures/kanban.yml"), File.join(@co, "config/kanban.yml"))
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" },
      "agents" => { "collector" => { "snapshot" => File.join(@coll, "sessions.json"),
                                     "read_socket" => File.join(@coll, "read.sock"), "tmux_timeout_seconds" => 2,
                                     "answer_timeout_seconds" => 9, } },
      "dictation" => "none", "terminal" => { "public_host" => "deny", "max_open" => 4 },
      "ci" => { "max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] } },
      "skills" => { "max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil },
      "launch" => { "trusted_paths" => [], "commands" => INVOCATIONS, "start_seconds" => 30, "scopes" => nil }
    ))
    File.write(File.join(@co, ".env"), <<~ENV)
      PROJECTS_ROOT=#{File.join(@base, 'projects')}
      PROJECTS_MOUNT=/projects
      LAUNCHER_RUN_DIR=#{File.join(@base, 'run')}
      LAUNCHER_STATE_DIR=#{File.join(@base, 'state')}
      CLAUDE_SESSIONS_DIR=#{File.join(@base, 'sessions')}
      CLAUDE_SESSION_URL=https://claude.example/{id}
    ENV
    # the agent: a copy of bash named claude, its cwd in the project
    FileUtils.cp(Open3.capture2("sh", "-c", "command -v bash").first.strip, File.join(@bin, "claude"))
    @agent = Process.spawn(File.join(@bin, "claude"), "-c", "sleep 300; :", %i[out err] => File::NULL, pgroup: true,
                                                                             chdir: File.join(@base, "projects/app"))
    # a Hermes pane: a copy of bash named hermes whose argv carries the launcher's bootstrap
    FileUtils.cp(File.join(@bin, "claude"), File.join(@bin, "hermes"))
    @hermes = Process.spawn(File.join(@bin, "hermes"), "-c", "sleep 300; : hermes_bootstrap", %i[out err] => File::NULL,
                            pgroup: true, chdir: File.join(@base, "projects/app"))
    ticks = File.read("/proc/#{@agent}/stat").then { |s| s[(s.rindex(")") + 2)..].split[19] }
    File.write(File.join(@base, "sessions/#{@agent}.json"), JSON.generate(
      "pid" => @agent, "procStart" => ticks, "sessionId" => "24ec2128-9e6a-4d9d-b0b1-3a3e7f2744a4", "status" => "idle",
      "name" => "app-7", "statusUpdatedAt" => 1_700_000_000_000
    ))
    # this uid's tmux server, as the collector finds it: a socket in $TMUX_TMPDIR/tmux-<uid>
    @tmux_server = UNIXServer.new(File.join(tmux_dir, "default"))
    b = @base
    stub("tmux", <<~SH)
      echo "$*" >> #{b}/tmux.log
      for a; do case "$a" in -S) ;; *) [ -n "$cmd" ] || case "$a" in /*|-*) ;; *) cmd=$a ;; esac ;; esac; done
      case "$cmd" in
        list-panes) echo "#{@agent} %7 0 0 0 1700000000 1700000100 1700000200 1 app_lead"
                    echo "#{@hermes} %8 0 0 0 1700000000 1700000100 1700000300 1 desk"; exit 0 ;;
        capture-pane) [ "$1" = -S ] && [ -f #{b}/hang-capture ] && exec sleep 3001; printf '❯ \\n'; exit 0 ;;
        display-message) echo "✳ app-7"; exit 0 ;;
        load-buffer) cat > #{b}/pasted; echo "load $*" >> #{b}/inputs; exit 0 ;;
        paste-buffer) [ -f #{b}/hang-paste ] && exec sleep 3001; echo "$cmd $*" >> #{b}/inputs; exit 0 ;;
        send-keys) echo "$cmd $*" >> #{b}/inputs; exit 0 ;;
      esac
      exit 1
    SH
    @env = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "TMUX_TMPDIR" => File.join(@base, "tmuxtmp") }
    @collector = spawn_up("bin/collector", "collector.log", File.join(@coll, "read.sock"))
    @launcher = spawn_up("bin/launcher", "launcher.log", File.join(@base, "run/launcher.sock"))
  end

  def teardown
    [@launcher, @collector].compact.each do |p|
      Process.kill("TERM", p)
      Process.wait(p)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    [@agent, @hermes].each do |p|
      Process.kill("TERM", -p)
      Process.wait(p)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    @tmux_server&.close
    FileUtils.rm_rf(@base)
  end

  def stub(name, body)
    File.write(File.join(@bin, name), "#!/bin/sh\ncmd=\n#{body}")
    File.chmod(0o755, File.join(@bin, name))
  end

  def spawn_up(prog, log, sock)
    path = File.join(@base, log)
    pid = Process.spawn(@env, RbConfig.ruby, File.join(@co, prog), %i[out err] => [path, "w"])
    Wait.for(-> { "#{prog}'s socket: #{File.read(path)}" }, seconds: BOOT_SECONDS, every: 0.1) do
      flunk "#{prog} exited: #{File.read(path)}" if Process.waitpid(pid, Process::WNOHANG)
      File.socket?(sock) && (UNIXSocket.open(sock) { true } rescue false)
    end
    pid
  end

  def launcher(req)
    UNIXSocket.open(File.join(@base, "run/launcher.sock")) do |s|
      s.puts(JSON.generate(req))
      JSON.parse(s.gets)
    end
  end

  def test_the_launcher_reads_what_the_collector_writes
    assert_equal 0o700, File.stat(@coll).mode & 0o777
    assert_equal [0o600, 0o600], [File.stat(File.join(@coll, "sessions.json")).mode & 0o777,
                                  File.stat(File.join(@coll, "read.sock")).mode & 0o777,]
    r = launcher("op" => "agents")
    assert_equal [true, 5, nil], r.values_at("ok", "interval_s", "collector_error"), r.inspect
    s = r["sessions"].first
    assert_equal ["app_lead", "default", 1], s.values_at("name", "socket", "windows"), s.inspect
    pane = s["panes"].first
    assert_equal ["0.0", "claude", "Claude", "idle", "app-7", 1_700_000_000.0, "/projects/app"],
                 pane.values_at("target", "engine", "engine_label", "status", "title", "status_at", "project_path")
    assert_equal "idle", pane.dig("screen", "state"), pane["screen"].inspect
    assert_equal "busyyaks's collector does not count subagents", pane.dig("unknown", "subagents_running")
    desk = r["sessions"].find { |x| x["name"] == "desk" }["panes"].first
    assert_equal ["hermes", "Hermes", nil], desk.values_at("engine", "engine_label", "status")
    refute desk["screen"].key?("error"), desk["screen"].inspect
  end

  # Hermes: listed, its state off its screen, but nothing is typed into it (its family is not typeable)
  def test_nothing_is_typed_into_hermes
    r = launcher("op" => "notify", "session" => "desk", "socket" => "default", "text" => "hello")
    assert_equal [false, true, "cannot type into hermes (family hermes)"], r.values_at("ok", "unsupported", "error")
    refute File.exist?(File.join(@base, "inputs")), "no tmux input"
  end

  def test_a_ping_is_pasted_through_the_collector
    r = launcher("op" => "notify", "session" => "app_lead", "socket" => "default", "text" => "card #5: $(id)\nsecond line")
    assert_equal({ "ok" => true }, r)
    assert_equal "card #5: $(id)\nsecond line", File.read(File.join(@base, "pasted"))
    inputs = File.readlines(File.join(@base, "inputs"), chomp: true)
    assert_equal 3, inputs.size, inputs.inspect
    assert_match(/\Aload -S \S+ load-buffer -b busyyaks-collector-\d+-\d+ -\z/, inputs[0])
    assert_match(/\Apaste-buffer -S \S+ paste-buffer -p -d -b busyyaks-collector-\S+ -t %7\z/, inputs[1])
    assert_match(/\Asend-keys -S \S+ send-keys -t %7 Enter\z/, inputs[2])
    assert_match(/send \d+ chars → app_lead \(%7\)/, File.read(File.join(@base, "collector.log")))
  end

  # review round 1: a hung tmux is killed at agents.collector.tmux_timeout_seconds and that request answers the error;
  # the input lock is released, so the next send goes through. Only the collector's calls hang (theirs carry -S; the
  # launcher's own capture-pane does not)
  def test_a_hung_tmux_is_an_error_answer_never_a_hang
    FileUtils.touch(File.join(@base, "hang-capture"))
    r = launcher("op" => "notify", "session" => "app_lead", "socket" => "default", "text" => "x")
    assert_equal [false, true], r.values_at("ok", "retry"), r.inspect
    assert_match(/\Acannot read its screen: tmux did not answer within 2s \(agents.collector.tmux_timeout_seconds\): killed\z/,
                 r["error"])
    FileUtils.rm(File.join(@base, "hang-capture"))
    FileUtils.touch(File.join(@base, "hang-paste"))
    r = launcher("op" => "notify", "session" => "app_lead", "socket" => "default", "text" => "x")
    assert_equal [false, true], r.values_at("ok", "retry"), r.inspect
    assert_match(/tmux did not answer within 2s/, r["error"])
    FileUtils.rm(File.join(@base, "hang-paste"))
    assert_equal({ "ok" => true }, launcher("op" => "notify", "session" => "app_lead", "socket" => "default", "text" => "y"))
    # this collector's children only (the flake stage runs copies of this file side by side)
    hung = Dir.glob("/proc/[0-9]*").select do |d|
      stat = File.read("#{d}/stat")
      stat[(stat.rindex(")") + 2)..].split[1].to_i == @collector && File.read("#{d}/cmdline") == "sleep\0" "3001\0"
    rescue SystemCallError
      false
    end
    assert_empty hung, "the hung tmux calls were killed"
  end

  # a collector that takes the connection and never answers (stopped): the launcher refuses by name at
  # answer_timeout_seconds, never parks
  def test_a_silent_collector_is_refused_by_name
    Process.kill("STOP", @collector)
    # kill returns before every thread has stopped (each stops on its way back to user space): ask only once all have
    Wait.for(-> { "every thread of the collector #{@collector} stopped" }, seconds: BOOT_SECONDS) do
      Dir.glob("/proc/#{@collector}/task/*/stat").all? { |f| File.read(f).then { |st| st[(st.rindex(")") + 2)] } == "T" }
    end
    r = launcher("op" => "agent_tasks", "session" => "app_lead", "socket" => "default")
    sock = File.join(@coll, "read.sock")
    assert_equal [false, "agent-session collector #{sock} did not answer within 9s", 503], r.values_at("ok", "error", "status")
  ensure
    Process.kill("CONT", @collector)
  end

  # one collector per dir: a second one is refused before it touches the live socket, which still answers
  def test_a_second_collector_is_refused
    log = File.join(@base, "second.log")
    pid = Process.spawn(@env, RbConfig.ruby, File.join(@co, "bin/collector"), %i[out err] => [log, "w"])
    _, st = Process.wait2(pid)
    refute st.success?
    assert_match(/another collector runs at #{Regexp.escape(@coll)} \(.*collector.lock is locked\): stop it first/,
File.read(log))
    answer = UNIXSocket.open(File.join(@coll, "read.sock")) do |s|
      s.puts('{"op":"ping"}')
      JSON.parse(s.gets)
    end
    assert_equal({ "ok" => true, "collector" => "busyyaks" }, answer)
  end

  def test_agent_tasks_say_the_collector_reads_none
    r = launcher("op" => "agent_tasks", "session" => "app_lead", "socket" => "default")
    assert_equal [false, "busyyaks's collector reads no subagents, workflows or background tasks", 404],
                 r.values_at("ok", "error", "status")
  end

  # Clear idle: this collector counts no subagents (null), so only the agent's own record saying idle makes a session a
  # candidate — the Hermes pane (no status, quiet for years, subagents unknown) is never one (card #479 round 1)
  def test_clear_idle_never_reads_unknown_subagents_as_none
    r = launcher("op" => "reap_preview")
    assert r["ok"], r.inspect
    assert_equal [%w[app_lead idle]], r["candidates"].map { |c| c.values_at("name", "reason") }
  end
end
