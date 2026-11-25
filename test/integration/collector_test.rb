# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/collector_sandbox"

# The contract (card #479): bin/collector writes the snapshot and serves the read socket; bin/launcher — the real one,
# unchanged — reads them. Both run as processes in a sandbox checkout, on the REAL /proc (the agent is a copy of bash
# named claude, so its comm is `claude`) and a stub tmux that answers list-panes with that process's pane and records
# every input. Asserted through the launcher's own ops:
#   - `agents`: the session with its pane, the engine label, the Claude Code record's status / title, its screen state;
#   - `notify`: the launcher's ping reaches the pane as ONE bracketed paste of the text through stdin, then Enter;
#   - `agent_tasks`: refused with the collector's reason.
class CollectorContractTest < Minitest::Test
  include CollectorSandbox

  def setup = sandbox_up!
  def teardown = sandbox_down!

  def test_the_launcher_reads_what_the_collector_writes
    assert_equal 0o700, File.stat(@coll).mode & 0o777
    assert_equal [0o600, 0o600], [File.stat(File.join(@coll, "sessions.json")).mode & 0o777,
                                  File.stat(File.join(@coll, "read.sock")).mode & 0o777,]
    r = launcher("op" => "agents")
    assert_equal [true, 5, nil], r.values_at("ok", "interval_s", "collector_error"), r.inspect
    s = r["sessions"].first
    assert_equal ["by_app_lead", "default", 1], s.values_at("name", "socket", "windows"), s.inspect
    pane = s["panes"].first
    assert_equal ["0.0", "claude", "Claude", "idle", "app-7", 1_700_000_000.0, "/projects/app"],
                 pane.values_at("target", "engine", "engine_label", "status", "title", "status_at", "project_path")
    assert_equal "idle", pane.dig("screen", "state"), pane["screen"].inspect
    assert_equal "busyyaks's collector does not count subagents", pane.dig("unknown", "subagents_running")
    desk = r["sessions"].find { |x| x["name"] == "by_desk" }["panes"].first
    assert_equal ["hermes", "Hermes", nil], desk.values_at("engine", "engine_label", "status")
    refute desk["screen"].key?("error"), desk["screen"].inspect
  end

  # the operator, 2026-11-24: "It must not appear in working agents if it's not run by busyyaks" and "busyyaks should
  # not be related to a session started from the terminal in any way" — a claude started by hand is never read by the
  # collector (not its process, its screen or its facts), never an agent, never typed into
  def test_a_session_started_from_the_terminal_is_never_read_listed_or_typed_into
    assert_equal %w[by_app_lead by_desk], launcher("op" => "agents")["sessions"].map { |x| x["name"] }.sort
    snap = JSON.parse(File.read(File.join(@coll, "sessions.json")))
    assert_equal %w[by_app_lead by_desk], snap["sessions"].map { |x| x["name"] }.sort, "the collector never reads it"
    r = launcher("op" => "notify", "session" => "hand", "socket" => "default", "text" => "hello")
    assert_equal [false, true], r.values_at("ok", "unsupported"), r.inspect
    assert_match(/not a session busyyaks started/, r["error"])
    refute File.exist?(File.join(@base, "inputs")), "no tmux input"
    # the sessions op itself never names it: a hand-run session never leaves this host
    refute_includes launcher("op" => "sessions")["sessions"].map { |x| x["name"] }, "hand"
  end

  # a session started by hand that is NAMED like busyyaks's (`by_…`) but was not launched by it: no record of its pane →
  # still never an agent, never typed into
  def test_a_by_named_session_busyyaks_did_not_launch_is_never_touched
    FileUtils.rm_rf(File.join(@base, "state/skills/by_desk"))
    assert_equal ["by_app_lead"], launcher("op" => "agents")["sessions"].map { |x| x["name"] }
    r = launcher("op" => "notify", "session" => "by_desk", "socket" => "default", "text" => "hello")
    assert_equal [false, true], r.values_at("ok", "unsupported"), r.inspect
    assert_match(/not a session busyyaks started/, r["error"])
    # and Stop never kills it: its name alone is no proof
    r = launcher("op" => "stop", "path" => "/projects/app", "sessions" => %w[by_desk])
    assert_equal [{ "name" => "by_desk", "stopped" => false, "reason" => "not started by busyyaks" }], r["results"]
    refute_match(/kill-session/, File.read(File.join(@base, "tmux.log")))
  end

  # The operator: busyyaks "should not be related in any way" to a session started from the terminal — every op that
  # acts on a named session refuses one busyyaks did not start (no stop, no dialog read, no key press, no git read, no
  # subagent read), and changes nothing
  def test_no_op_acts_on_a_session_busyyaks_did_not_start
    refusals = {
      "dialog" => { "op" => "dialog", "session" => "hand" },
      "answer" => { "op" => "answer", "session" => "hand", "key" => "1" },
      "git" => { "op" => "git", "session" => "hand" },
      "agent_tasks" => { "op" => "agent_tasks", "session" => "hand", "socket" => "default" },
    }
    refusals.each do |op, req|
      r = launcher(req)
      refute r["ok"], "#{op}: #{r.inspect}"
      assert_match(/not a session busyyaks started/, r["error"], op)
    end
    r = launcher("op" => "stop", "path" => "/projects/app", "sessions" => %w[hand nobody])
    assert_equal [{ "name" => "hand", "stopped" => false, "reason" => "not started by busyyaks" },
                  { "name" => "nobody", "stopped" => false, "reason" => "not running" },], r["results"],
                 "a hand-run session is said as such (never \"not running\"), and never stopped"
    refute File.exist?(File.join(@base, "inputs")), "no key was pressed"
    refute_match(/send-keys|kill-session/, File.read(File.join(@base, "tmux.log")))
  end

  # a `by_` session with a stage whose record names ANOTHER process (the name reused after busyyaks's own session ended,
  # by a session started by hand): not busyyaks's — never listed, never typed into
  def test_a_record_of_another_process_is_no_proof
    rec = File.join(@base, "state/skills/by_desk/launched.json")
    File.write(rec, JSON.generate(JSON.parse(File.read(rec)).merge("start_ticks" => 1)))
    assert_equal ["by_app_lead"], launcher("op" => "agents")["sessions"].map { |x| x["name"] }
    r = launcher("op" => "notify", "session" => "by_desk", "socket" => "default", "text" => "hello")
    assert_equal [false, true], r.values_at("ok", "unsupported"), r.inspect
  end

  # Hermes busyyaks launched but not in queue mode (no hermes-board record): nothing typed into it
  def test_nothing_is_typed_into_hermes
    r = launcher("op" => "notify", "session" => "by_desk", "socket" => "default", "text" => "hello")
    assert_equal [false, true, "cannot type into hermes (family hermes: not launched by busyyaks in queue mode)"],
r.values_at("ok", "unsupported", "error")
    refute File.exist?(File.join(@base, "inputs")), "no tmux input"
  end

  def test_a_ping_is_pasted_through_the_collector
    r = launcher("op" => "notify", "session" => "by_app_lead", "socket" => "default", "text" => "card #5: $(id)\nsecond line")
    assert_equal({ "ok" => true }, r)
    assert_equal "card #5: $(id)\nsecond line", File.read(File.join(@base, "pasted"))
    inputs = File.readlines(File.join(@base, "inputs"), chomp: true)
    assert_equal 3, inputs.size, inputs.inspect
    assert_match(/\Aload -S \S+ load-buffer -b busyyaks-collector-\d+-\d+ -\z/, inputs[0])
    assert_match(/\Apaste-buffer -S \S+ paste-buffer -p -d -b busyyaks-collector-\S+ -t %7\z/, inputs[1])
    assert_match(/\Asend-keys -S \S+ send-keys -t %7 Enter\z/, inputs[2])
    assert_match(/send \d+ chars → by_app_lead \(%7\)/, File.read(File.join(@base, "collector.log")))
  end

  # review round 1: a hung tmux is killed at agents.collector.tmux_timeout_seconds and that request answers the error;
  # the input lock is released, so the next send goes through. Only the collector's calls hang (theirs carry -S; the
  # launcher's own capture-pane does not)
  def test_a_hung_tmux_is_an_error_answer_never_a_hang
    FileUtils.touch(File.join(@base, "hang-capture"))
    r = launcher("op" => "notify", "session" => "by_app_lead", "socket" => "default", "text" => "x")
    assert_equal [false, true], r.values_at("ok", "retry"), r.inspect
    assert_match(/\Acannot read its screen: tmux did not answer within 2s \(agents.collector.tmux_timeout_seconds\): killed\z/,
                 r["error"])
    FileUtils.rm(File.join(@base, "hang-capture"))
    # a paste that hung and was killed may have typed: outcome unknown, ended (`unsupported`), never resent
    FileUtils.touch(File.join(@base, "hang-paste"))
    r = launcher("op" => "notify", "session" => "by_app_lead", "socket" => "default", "text" => "x")
    assert_equal [false, true, true], r.values_at("ok", "unsupported", "unconfirmed"), r.inspect
    assert_match(/\Aoutcome unknown, not resent \(it may have been typed\): the paste failed .*tmux did not answer within 2s/,
                 r["error"])
    FileUtils.rm(File.join(@base, "hang-paste"))
    assert_equal({ "ok" => true }, launcher("op" => "notify", "session" => "by_app_lead", "socket" => "default", "text" => "y"))
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
    r = launcher("op" => "agent_tasks", "session" => "by_app_lead", "socket" => "default")
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

  # a snapshot whose tmux walk failed leaves the session out: unknown, so the ping waits (retry) — never "not running"
  # (public review round 1)
  def test_a_session_missing_from_a_failed_snapshot_is_retried_not_gone
    FileUtils.touch(File.join(@base, "fail-list"))
    snap = File.join(@coll, "sessions.json")
    Wait.for(-> { "a snapshot with the tmux error" }, seconds: BOOT_SECONDS, every: 0.2) do
      JSON.parse(File.read(snap))["error"].to_s.include?("server exited unexpectedly")
    rescue JSON::ParserError
      false
    end
    r = launcher("op" => "notify", "session" => "by_app_lead", "socket" => "default", "text" => "x")
    assert_equal [false, true, nil], r.values_at("ok", "retry", "gone"), r.inspect
    # tmux unreadable: busyyaks cannot even tell the session is its own — retried, never "gone"
    assert_match(/\Atmux unreadable: cannot tell whether by_app_lead is busyyaks's\z/, r["error"])
    refute File.exist?(File.join(@base, "inputs")), "nothing typed"
  end

  def test_agent_tasks_say_the_collector_reads_none
    r = launcher("op" => "agent_tasks", "session" => "by_app_lead", "socket" => "default")
    assert_equal [false, "busyyaks's collector reads no subagents, workflows or background tasks", 404],
                 r.values_at("ok", "error", "status")
  end

  # Clear idle: this collector counts no subagents (null), so only the agent's own record saying idle makes a session a
  # candidate — the Hermes pane (no status, quiet for years, subagents unknown) is never one (card #479 round 1)
  def test_clear_idle_never_reads_unknown_subagents_as_none
    r = launcher("op" => "reap_preview")
    assert r["ok"], r.inspect
    assert_equal [%w[by_app_lead idle]], r["candidates"].map { |c| c.values_at("name", "reason") }
  end

  # U9, the operator: "a ping that arrives while a session is still starting is delivered later, never lost". The real
  # bin/launcher, a launch held at `tmux new-session` (the test holds it, not the clock): a `notify` for that session
  # answers retry "still starting" — the notifier keeps the ping — and types nothing; once the start has ended (here
  # refused: the sandbox starts nothing), the same ping is `gone`, never `unsupported` (a session busyyaks did not start)
  def test_a_ping_that_arrives_while_a_session_is_still_starting_is_retried_never_lost
    FileUtils.touch(File.join(@base, "hold-start"))
    start = Thread.new { plain_launch("by_app") }
    Wait.for(-> { "the launch at tmux new-session: #{File.read(File.join(@base, 'launcher.log'))}" },
             seconds: BOOT_SECONDS) do
      flunk "the launch ended before its start: #{start.value.inspect}" unless start.alive?
      File.exist?(File.join(@base, "starting"))
    end
    r = launcher("op" => "notify", "session" => "by_app", "socket" => "default", "text" => "assigned: card #5")
    assert_equal [false, true, "session by_app is still starting"], r.values_at("ok", "retry", "error"), r.inspect
    refute r.key?("gone") || r.key?("unsupported"), "never dropped while it starts"
    refute File.exist?(File.join(@base, "inputs")), "nothing typed into a session that is starting"
    assert start.alive?, "the launch is still in flight"
    FileUtils.rm(File.join(@base, "hold-start"))
    done = Wait.join(start, "the held launch's answer", seconds: BOOT_SECONDS).value
    assert_equal [false, "RuntimeError: tmux failed: the sandbox starts no session"], done.values_at("ok", "error"),
                 done.inspect
    r = launcher("op" => "notify", "session" => "by_app", "socket" => "default", "text" => "assigned: card #5")
    assert_equal [false, true, "session by_app is not running"], r.values_at("ok", "gone", "error"), r.inspect
    refute File.exist?(File.join(@base, "inputs"))
  end
end
