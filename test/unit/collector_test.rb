# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "socket"
require "etc"
require_relative "../support/wait"
require "minitest/mock"
require_relative "../../lib/busyyaks/collector"
require_relative "../../lib/busyyaks/engines"
require_relative "../../lib/busyyaks/agent_collector"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/session_dialog"

# busyyaks's collector (card #479) on a FAKE /proc tree and a fake tmux (a runner that answers from a table and records
# every argv): no host tmux, no host process, nothing outside the test's tmp dir. Standalone (no test_helper): the host
# stage runs it on the oldest host Ruby. The launcher-side contract (bin/launcher reading what bin/collector writes) is
# test/integration/collector_test.rb.
class CollectorTest < Minitest::Test
  C = Busyyaks::Collector
  CLK = 100
  BOOT = 1_000_000.0

  # a fake tmux: list-panes answers rows; capture-pane the screen; every call recorded as [argv, stdin]
  class FakeTmux
    attr_reader :calls
    attr_accessor :screen, :fail

    def initialize(lines)
      @lines = lines
      @calls = []
      @screen = "❯ \n"
      @fail = {}
    end

    def call(argv, stdin, seconds)
      @calls << [argv, stdin, seconds]
      cmd = argv[3]
      return ["", @fail[cmd], false] if @fail[cmd]

      case cmd
      when "list-panes" then [@lines.fetch(File.basename(argv[2]), ""), "", true]
      when "capture-pane" then [@screen, "", true]
      else ["", "", true]
      end
    end
  end

  def setup
    # under $HOME: the dir rule refuses a dir whose parent (a sticky /tmp) others may write
    @dir = File.realpath(Dir.mktmpdir("collector", Etc.getpwuid(Process.uid).dir))
    @proc = File.join(@dir, "proc")
    @sessions = File.join(@dir, "cc-records")
    @tmuxdir = File.join(@dir, "tmux-#{Process.uid}")
    FileUtils.mkdir_p([@proc, @sessions, @tmuxdir])
    File.write(File.join(@proc, "stat"), "cpu 1 2 3\nbtime #{BOOT.to_i}\n")
    @servers = []
  end

  def teardown
    @servers.each(&:close)
    FileUtils.rm_rf(@dir)
  end

  def process(pid, ppid, comm, argv, ticks: 500, cwd: "/projects/app", exe: nil)
    d = File.join(@proc, pid.to_s)
    FileUtils.mkdir_p(d)
    File.write(File.join(d, "stat"), "#{pid} (#{comm}) S #{ppid} #{([0] * 17).join(' ')} #{ticks} 0 0\n")
    File.binwrite(File.join(d, "cmdline"), "#{argv.join("\0")}\0")
    File.symlink(cwd, File.join(d, "cwd"))
    File.symlink(exe, File.join(d, "exe")) if exe
  end

  def record(pid, ticks: 500, **over)
    File.write(File.join(@sessions, "#{pid}.json"), JSON.generate(
      { "pid" => pid, "procStart" => ticks.to_s, "sessionId" => "24ec2128-9e6a-4d9d-b0b1-3a3e7f2744a4",
        "status" => "busy", "name" => "app-1", "statusUpdatedAt" => 1_700_000_000_123, "cwd" => "/projects/app", }
        .merge(over)
    ))
  end

  def socket(label)
    @servers << UNIXServer.new(File.join(@tmuxdir, label))
  end

  # pane rows in tmux's FORMAT order (session_name last, with a space in it)
  def row(pane_pid, pane_id, name, win: 0, pane: 0)
    "#{pane_pid} #{pane_id} #{win} #{pane} 1 1700000000 1700000100 1700000200 2 #{name}\n"
  end

  def one(list)
    assert_equal 1, list.size, list.inspect
    list.first
  end

  def procfs = C::Procfs.new(@proc, clk_tck: CLK)
  def families = C.families(claude_sessions_dir: @sessions)
  def tmux(fake) = C::Tmux.new(dir: @tmuxdir, uid: Process.uid, runner: fake, timeout: 3)

  # a box with: a Claude Code pane (bash → claude → its own bash → a subagent claude, never a second session), a Hermes
  # pane, a pane running only a shell, and a process named hermes without the bootstrap (not Hermes)
  def box
    process(10, 1, "bash", ["bash"])
    process(11, 10, "claude", ["claude", "--model", "opus", "--effort", "high", "--", "--model", "x"],
            exe: "/home/u/.local/share/claude/versions/2.1.325")
    process(12, 11, "bash", ["bash", "-c", "x"])
    process(13, 12, "claude", ["claude", "-p"])
    process(20, 1, "bash", ["bash"])
    process(21, 20, "hermes", ["/h/python3", "-I", "-c", "import hermes_bootstrap", "-q", "secret prompt"], ticks: 700)
    process(30, 1, "bash", ["bash"])
    process(40, 1, "bash", ["bash"])
    process(41, 40, "hermes", ["hermes-lookalike"])
    record(11)
    socket("default")
    FakeTmux.new("default" => row(10, "%1", "app lead") + row(20, "%2", "desk") + row(30, "%3", "shell") +
                              row(40, "%4", "fake", win: 1) + "garbage line\n")
  end

  def build(fake)
    rows, error = tmux(fake).rows
    C::Snapshot.build(rows, procfs: procfs, families: families, interval_s: 5, error: error, now: 42.0, host: "h")
  end

  def test_snapshot_lists_each_agent_pane_with_its_family_facts
    snap, targets = build(box)
    assert_equal [1, 42.0, "h", 5, nil], snap.values_at("version", "generated_at", "host", "interval_s", "error")
    assert_equal ["app lead", "desk"], snap["sessions"].map { |s| s["name"] }, "no shell-only pane, no lookalike"
    lead = snap["sessions"].first
    assert_equal({ "name" => "app lead", "socket" => "default", "attached" => 1, "created" => 1_700_000_000,
                   "activity" => 1_700_000_200, "windows" => 2, }, lead.except("panes"))
    pane = lead["panes"].then { one(_1) }
    assert_equal [%w[target 0.0], %w[pane_id %1], ["pid", 11], ["cwd", "/projects/app"], ["started", BOOT + 5.0],
                  %w[engine claude], %w[model opus], %w[effort high], %w[version 2.1.325],
                  ["session_id", "24ec2128-9e6a-4d9d-b0b1-3a3e7f2744a4"], %w[status busy], ["waiting_for", nil],
                  %w[title app-1], ["status_at", 1_700_000_000.123], ["context", nil], ["subagents_running", nil],],
                 pane.slice(*%w[target pane_id pid cwd started engine model effort version session_id status waiting_for
                                title status_at context subagents_running]).to_a
    assert_equal %w[context subagents_running waiting_for], pane["unknown"].keys.sort, "each nil says why"
    assert_match(/never reads/, pane["unknown"]["context"])
    hermes = snap["sessions"].last["panes"].then { one(_1) }
    assert_equal ["hermes", 21, BOOT + 7.0], hermes.values_at("engine", "pid", "started")
    assert_equal C::FACTS.sort, hermes["unknown"].keys.sort, "Hermes: every fact unknown, with the reason"
    refute_match(/secret prompt/, JSON.generate(snap), "argv never leaves")
    t = targets[["default", "app lead"]]
    assert_equal [11, 500, "claude", "%1"], [t.pid, t.start_ticks, t.family.name, t.pane_id]
    assert_equal %w[default desk hermes], [targets[%w[default desk]].socket, targets[%w[default desk]].name,
                                                 targets[%w[default desk]].family.name,]
  end

  # every pane carries every key the launcher allowlists (bin/launcher PANE_KEYS)
  # `hermes gateway run` is Hermes's daemon (its bootstrap, then "gateway" after the -c script), never a session
  def test_the_hermes_gateway_is_no_session
    process(50, 1, "bash", ["bash"])
    process(51, 50, "hermes", ["/h/python3", "-I", "-c", "import hermes_bootstrap", "gateway", "run"])
    process(60, 1, "bash", ["bash"])
    process(61, 60, "hermes", ["/h/python3", "-I", "-c", "import hermes_bootstrap", "chat"])
    socket("default")
    snap, = build(FakeTmux.new("default" => row(50, "%5", "gw") + row(60, "%6", "chat")))
    assert_equal ["chat"], snap["sessions"].map { |x| x["name"] }
  end

  # a cwd is bytes: one that is not UTF-8 shows U+FFFD and the snapshot still writes (no crash loop)
  def test_a_cwd_that_is_not_utf8_still_writes
    process(10, 1, "bash", ["bash"])
    process(11, 10, "claude", ["claude"], cwd: "/projects/caf\xE9".b)
    record(11)
    socket("default")
    snap, = build(FakeTmux.new("default" => row(10, "%1", "app")))
    cwd = snap["sessions"].first["panes"].first["cwd"]
    assert_equal "/projects/caf\uFFFD", cwd
    assert JSON.generate(snap)
  end

  # an unreadable proc root is an error (the snapshot's, via bin/collector's collect), never "no agents"
  def test_an_unreadable_proc_root_raises
    assert_raises(Errno::ENOENT) { C::Procfs.new(File.join(@dir, "no-proc"), clk_tck: CLK).processes }
  end

  def test_every_pane_has_the_launchers_keys
    snap, = build(box)
    src = File.read(File.expand_path("../../bin/launcher", __dir__))
    keys = src[/^PANE_KEYS = %w\[([^\]]*)\]/, 1].split
    snap["sessions"].flat_map { |s| s["panes"] }.each { |p| assert_empty keys - p.keys, p["engine"] }
  end

  # a FIFO where the record should be would park the collector's loop on its read: only a regular file is read
  def test_a_claude_record_that_is_no_regular_file_is_not_read
    fake = box
    File.delete(File.join(@sessions, "11.json")) if File.exist?(File.join(@sessions, "11.json"))
    File.mkfifo(File.join(@sessions, "11.json"))
    pane = build(fake).first["sessions"].first["panes"].then { one(_1) }
    assert_nil pane["status"]
    assert_match(/11\.json is not a regular file/, pane["unknown"]["status"])
  end

  def test_claude_record_is_trusted_only_for_its_own_process
    fake = box
    record(11, ticks: 499) # a recycled pid: another process's record
    pane = build(fake).first["sessions"].first["panes"].then { one(_1) }
    assert_equal [nil, nil, nil], pane.values_at("status", "session_id", "title")
    assert_match(/another process's \(pid reused\)/, pane["unknown"]["status"])
    File.delete(File.join(@sessions, "11.json"))
    pane = build(fake).first["sessions"].first["panes"].then { one(_1) }
    assert_match(/no Claude Code record/, pane["unknown"]["session_id"])
    record(11, "status" => "waiting", "waitingFor" => "approve Bash")
    pane = build(fake).first["sessions"].first["panes"].then { one(_1) }
    assert_equal ['waiting', 'approve Bash'], pane.values_at("status", "waiting_for")
    record(11, "status" => "shell")
    pane = build(fake).first["sessions"].first["panes"].then { one(_1) }
    assert_nil pane["status"]
    assert_match(/"shell", not one of idle · busy · waiting/, pane["unknown"]["status"])
  end

  def test_only_this_uids_sockets_and_dead_servers_are_no_sessions
    fake = box
    socket("work")
    File.symlink(File.join(@tmuxdir, "default"), File.join(@tmuxdir, "link"))
    File.write(File.join(@tmuxdir, "file"), "")
    assert_equal %w[default work], tmux(fake).labels
    fake.fail["list-panes"] = "no server running on #{@tmuxdir}/work"
    assert_equal [[], nil], tmux(fake).rows, "a dead server: zero sessions, no error"
    fake.fail["list-panes"] = "permission denied"
    rows, error = tmux(fake).rows
    assert_empty rows
    assert_equal "tmux default: permission denied; tmux work: permission denied", error
    assert(fake.calls.all? { |argv, _| argv[0, 2] == ["tmux", "-S"] && argv[2].start_with?("#{@tmuxdir}/") })
    assert_equal [], C::Tmux.new(dir: File.join(@dir, "none"), uid: Process.uid, runner: fake, timeout: 3).labels
  end

  def test_tmux_not_installed_is_the_snapshots_error
    socket("default")
    missing = ->(_argv, _stdin, _seconds) { ["", "#{C::Tmux::NOT_RUNNABLE} (tmux: Errno::ENOENT)", false] }
    t = C::Tmux.new(dir: @tmuxdir, uid: Process.uid, runner: missing, timeout: 3)
    rows, error = t.rows
    assert_equal [], rows
    assert_match(/\Atmux is not installed/, error)
  end

  def test_tmux_dir_follows_tmux_tmpdir
    assert_equal "/tmp/tmux-7", C::Tmux.dir_for({}, 7)
    assert_equal "/run/x/tmux-7", C::Tmux.dir_for({ "TMUX_TMPDIR" => "/run/x" }, 7)
  end

  def test_write_atomic_replaces_the_file_owner_only
    path = File.join(@dir, "s.json")
    File.write(path, "old")
    C::Snapshot.write_atomic(path, "new")
    assert_equal ["new", 0o600], [File.read(path), File.stat(path).mode & 0o777]
    assert_equal ["s.json"], Dir.children(@dir).grep(/s\.json/), "no temp file left"
  end

  def test_families_match_the_engines_config
    engines = Busyyaks::Engines.load(nil)
    assert_nil C.check_engines!(families, engines)
    assert_equal %w[claude hermes], families.map(&:name)
    assert_equal Busyyaks::Engines::FAMILIES.keys.sort, families.map(&:name).sort, "a family each side, by the same name"
    relabeled = Busyyaks::Engines.load({ "hermes" => { "label" => "H", "family" => "claude" } })
    e = assert_raises(C::Invalid) { C.check_engines!(families, relabeled) }
    assert_match(/hermes is configured as family claude/, e.message)
  end

  def test_dir_must_be_one_private_dir_outside_every_mount
    run = File.join(@dir, "run")
    paths = Busyyaks::AgentCollector::Paths
    ok = File.join(@dir, "state", "collector")
    assert_equal ok, C.dir!(paths.new(snapshot: "#{ok}/s.json", read_socket: "#{ok}/r.sock"),
                            projects_root: File.join(@dir, "projects"), checkout: File.join(@dir, "co"), run_dir: run,
                            uid: Process.uid)
    assert_equal 0o700, File.stat(ok).mode & 0o777
    e = assert_raises(C::Invalid) do
      C.dir!(paths.new(snapshot: "#{ok}/s.json", read_socket: "#{@dir}/r.sock"), projects_root: "/p", checkout: "/c",
                                                                                  run_dir: run, uid: Process.uid)
    end
    assert_match(/same dir/, e.message)
    e = assert_raises(C::Invalid) do
      C.dir!(paths.new(snapshot: "#{run}/c/s.json", read_socket: "#{run}/c/r.sock"), projects_root: "/p", checkout: "/c",
                                                                                      run_dir: run, uid: Process.uid)
    end
    assert_match(/agents.collector dir .* overlaps LAUNCHER_RUN_DIR/, e.message)
  end

  # ── the read socket ──────────────────────────────────────────────────────────────────────────────────────────────

  def server(fake, typeable: ->(e) { e == "claude" })
    latest = C::Latest.new
    latest.set(build(fake).last)
    @log = []
    @pauses = []
    C::Server.new(latest: latest, procfs: procfs, tmux: tmux(fake), typeable: typeable, log: ->(m) { @log << m },
                  pause: ->(s) { @pauses << s },
                  dialog: ->(t) { AgentsKanban::SessionDialog.parse(t)&.slice(:question, :options, :hash) })
  end

  def inputs(fake)
    fake.calls.reject { |argv, _| %w[list-panes capture-pane].include?(argv[3]) }.map { |argv, s, _| [argv.drop(3), s] }
  end

  def test_send_pastes_the_text_then_enter_into_the_snapshots_pane_only
    fake = box
    s = server(fake)
    text = "line one\n$(rm -rf ~); `x` ; \e[31mred\e[0m\r\nend\u0085"
    assert_equal({ ok: true }, s.handle("op" => "send", "session" => "app lead", "socket" => "default", "text" => text,
                                        "pane" => "%2"))
    sent = inputs(fake)
    buf = sent.first[0][2]
    assert_match(/\Abusyyaks-collector-\d+-\d+\z/, buf)
    assert_equal [[["load-buffer", "-b", buf, "-"], "line one\n$(rm -rf ~); `x` ; [31mred[0m\nend"],
                  [["paste-buffer", "-p", "-d", "-b", buf, "-t", "%1"], nil], [["send-keys", "-t", "%1", "Enter"], nil],],
                 sent, "the text only through stdin, control characters gone, the pane from the snapshot (not the request's)"
    assert_equal [C::Server::PASTE_SETTLE_S], @pauses
    assert_match(/send \d+ chars → app lead \(%1\)\z/, @log.then { one(_1) })
    refute_match(/line one/, @log.then { one(_1) }, "the log never carries the text")
  end

  def test_send_without_submit_presses_no_enter
    fake = box
    r = server(fake).handle("op" => "send", "session" => "app lead", "text" => "draft", "submit" => false)
    assert_equal({ ok: true }, r)
    assert_equal %w[load-buffer paste-buffer], inputs(fake).map { |a, _| a.first }
  end

  def test_send_refusals_type_nothing
    fake = box
    s = server(fake)
    refusals = {
      { "session" => "nobody", "text" => "x" } => "no_session",
      { "session" => "app lead", "socket" => "../x", "text" => "x" } => "invalid_request",
      { "session" => "app lead", "text" => " \u0007 " } => "invalid_request",
      { "session" => "app lead", "text" => "x" * 16_001 } => "invalid_request",
      { "session" => "app lead", "text" => "\xff".dup.force_encoding("UTF-8") } => "invalid_request",
      { "session" => "desk", "text" => "x" } => "unsupported",
    }
    refusals.each do |req, type|
      assert_equal type, s.handle(req.merge("op" => "send"))[:error][:type], req.inspect
    end
    fake.screen = "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel\n"
    r = s.handle("op" => "send", "session" => "app lead", "text" => "x")
    assert_equal "dialog", r[:error][:type], "a paste + Enter would answer the dialog"
    assert_empty inputs(fake)
  end

  # the agent exited (or its pid was reused) since the snapshot: the pane is a shell now
  def test_send_refused_once_the_agent_is_gone
    fake = box
    s = server(fake)
    FileUtils.rm_rf(File.join(@proc, "11"))
    process(11, 10, "bash", ["bash"])
    assert_equal "no_session", s.handle("op" => "send", "session" => "app lead", "text" => "ls")[:error][:type]
    FileUtils.rm_rf(File.join(@proc, "11"))
    process(11, 10, "claude", ["claude"], ticks: 900)
    assert_equal "no_session", s.handle("op" => "send", "session" => "app lead", "text" => "ls")[:error][:type]
    assert_empty inputs(fake)
  end

  # nothing typed yet (the buffer load failed) → tmux, worth a retry; the paste or the Enter failed → unconfirmed: the
  # text may be on the screen, so it is never sent again (public review round 1)
  def test_send_tmux_failure_before_the_paste_is_retryable_after_it_unconfirmed
    fake = box
    fake.fail["load-buffer"] = "no server"
    r = server(fake).handle("op" => "send", "session" => "app lead", "text" => "x")
    assert_equal({ type: "tmux", message: "no server" }, r[:error])
    assert_equal %w[load-buffer], inputs(fake).map { |a, _| a.first }, "no paste after a failed load"

    fake.fail.clear
    fake.fail["paste-buffer"] = "can't find pane %1"
    r = server(fake).handle("op" => "send", "session" => "app lead", "text" => "x")
    assert_equal({ type: "unconfirmed", message: "the paste failed and may have been typed in part: can't find pane %1" },
                 r[:error])
    refute(inputs(fake).any? { |a, _| a.first == "send-keys" }, "no Enter after a failed paste")

    fake.fail.clear
    fake.fail["send-keys"] = "lost"
    r = server(fake).handle("op" => "send", "session" => "app lead", "text" => "x")
    assert_equal({ type: "unconfirmed", message: "pasted, then the Enter failed: lost" }, r[:error])
  end

  def test_screen_and_tasks_and_unknown_ops
    fake = box
    s = server(fake)
    fake.screen = "Bash command\n  rm x\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel\n"
    r = s.handle("op" => "screen", "session" => "app lead")
    assert_equal [true, fake.screen, "claude"], r.values_at(:ok, :text, :engine)
    assert_match(/\ADo you want to proceed\?\z|\nDo you want to proceed\?\z/, r[:dialog][:question])
    fake.screen = "❯ \n"
    assert_nil s.handle("op" => "screen", "session" => "desk")[:dialog]
    assert_equal({ ok: false, error: { type: "unsupported", message: C::Server::TASKS } },
                 s.handle("op" => "tasks", "session" => "app lead"))
    assert_equal "invalid_request", s.handle("op" => "key", "session" => "app lead")[:error][:type]
    assert_equal "invalid_request", s.handle([1])[:error][:type]
    fake.fail["capture-pane"] = "no pane"
    assert_equal({ type: "tmux", message: "no pane" }, s.handle("op" => "screen", "session" => "app lead")[:error])
  end

  # SCREEN_MAX is bytes: a screen of multibyte characters over it is cut by bytes, the half character dropped
  def test_a_long_screen_is_cut_by_bytes
    fake = box
    fake.screen = "x" + ("❯" * (C::Server::SCREEN_MAX / 3 + 10))
    r = server(fake).handle("op" => "screen", "session" => "app lead")
    assert r[:ok], r.inspect
    assert r[:text].valid_encoding?
    assert_operator r[:text].bytesize, :<=, C::Server::SCREEN_MAX
    assert_operator r[:text].bytesize, :>, C::Server::SCREEN_MAX - 3
    assert r[:text].end_with?("❯")
  end

  # the wire: one line in, one line out, over a real unix socket pair
  def test_serve_answers_one_json_line
    s = server(box)
    [["{\"op\":\"tasks\",\"session\":\"app lead\"}\n", "unsupported"], ["nope\n", "invalid_request"],
     ["#{'x' * (C::Server::REQUEST_MAX + 10)}\n", "invalid_request"],].each do |line, type|
      a, b = UNIXSocket.pair
      a.write(line)
      s.serve(b)
      assert_equal type, JSON.parse(a.gets).dig("error", "type"), line[0, 40]
      a.close
    end
  end

  # review round 1: every tmux call carries its deadline; a timed-out call is that request's error and the input lock
  # is free again (the next send goes through)
  def test_every_tmux_call_has_its_deadline_and_a_timeout_is_an_error_answer
    fake = box
    s = server(fake)
    assert_equal true, s.handle("op" => "screen", "session" => "app lead")[:ok]
    assert(fake.calls.all? { |_, _, seconds| seconds == 3 }, fake.calls.inspect)
    assert_raises(ArgumentError) { C::Tmux.new(dir: @tmuxdir, uid: Process.uid, runner: fake, timeout: 0) }
    assert_raises(ArgumentError) { C::Tmux.new(dir: @tmuxdir, uid: Process.uid, runner: fake, timeout: nil) }

    fake.fail["load-buffer"] = C::Tmux.timed_out(3)
    r = s.handle("op" => "send", "session" => "app lead", "text" => "x")
    assert_equal({ type: "tmux", message: "tmux did not answer within 3s (agents.collector.tmux_timeout_seconds): killed" },
                 r[:error])
    fake.fail.clear
    assert_equal({ ok: true }, s.handle("op" => "send", "session" => "app lead", "text" => "y"), "the lock was released")
    fake.fail["capture-pane"] = C::Tmux.timed_out(3)
    assert_match(/did not answer within 3s/, s.handle("op" => "screen", "session" => "app lead")[:error][:message])
  end

  # review round 1: a thread that dies ends the collector (logged with the reason, exit 1); one that ends is fine
  def test_a_supervised_thread_that_dies_ends_the_collector
    died = Queue.new
    log = Queue.new
    C.supervised("accept", log: ->(m) { log << m }, die: ->(code) { died << code }) { raise Errno::EMFILE }
    assert_equal 1, Wait.pop(died, "the collector's exit", seconds: 10)
    assert_equal "collector: the accept thread died (Errno::EMFILE: Too many open files): exiting so the unit restarts it",
                 Wait.pop(log, "the log line", seconds: 10)
    ok = C.supervised("connection", log: ->(m) { log << m }, die: ->(code) { died << code }) { :served }
    Wait.join(ok, "a served connection", seconds: 10)
    assert_empty died
    assert_empty log
  end

  # the whole line within the deadline: a peer that sends half a line and stops is answered, never parks the reader
  def test_read_line_bounds_the_whole_line
    rl = Busyyaks::AgentCollector
    a, b = UNIXSocket.pair
    a.write("{\"op\":\"pi")
    ticks = [0.0, 0.0, 100.0].each
    Busyyaks::Clock.stub(:monotonic, -> { ticks.next }) do
      e = assert_raises(rl::Slow) { rl.read_line(b, 15, max: 100) }
      assert_equal "no whole line within 15s", e.message
    end
    a.close
    b.close
    # one line per connection: what follows the newline is not this line
    a, b = UNIXSocket.pair
    a.write("{\"op\":\"ping\"}\n{\"next")
    assert_equal "{\"op\":\"ping\"}\n", rl.read_line(b, 15, max: 100)
    a.write("x" * 150 + "\n")
    assert_raises(rl::TooLarge) { rl.read_line(b, 15, max: 100) }
    a.close
    c, d = UNIXSocket.pair
    c.write("{\"ok\":true}")
    c.close
    assert_equal "{\"ok\":true}", rl.read_line(d, 15, max: 100), "EOF ends a line without its newline"
    e, f = UNIXSocket.pair
    e.close
    assert_nil rl.read_line(f, 15, max: 100), "EOF before any byte"
    [b, d, f].each(&:close)
  end

  def test_serve_answers_a_partial_request_line_and_a_ping
    s = server(box)
    a, b = UNIXSocket.pair
    a.write("{\"op\":")
    ticks = [0.0, 0.0, 100.0].each
    Busyyaks::Clock.stub(:monotonic, -> { ticks.next }) { s.serve(b) }
    assert_equal({ "type" => "invalid_request", "message" => "no whole request line within 15s" },
                 JSON.parse(a.gets)["error"])
    a.close
    a, b = UNIXSocket.pair
    a.write("{\"op\":\"ping\"}\n")
    s.serve(b)
    assert_equal({ "ok" => true, "collector" => "busyyaks" }, JSON.parse(a.gets))
    a.close
  end
end
