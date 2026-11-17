# frozen_string_literal: true

require "test_helper"
require "busyyaks/config"
require "socket"
require "tmpdir"

class ConfigTest < Minitest::Test
  OK = { "roots" => [{ "path" => "/p", "prefix" => "" }], "search_depth" => 2, "owner_remotes" => ["github.com/me/"],
         "author_emails" => ["Me@x.io"], "window_days" => 7, "reap_protect" => [], "auth" => { "provider" => "none" },
         "agents" => { "collector" => "none" }, "dictation" => "none",
         "terminal" => TERMINAL_DENY, "ci" => CI_SETTINGS, "skills" => SKILLS_SETTINGS, "launch" => LAUNCH_CLAUDE, }.freeze

  def test_valid = assert_equal ["me@x.io"], Busyyaks::Config.new(OK).author_emails

  # dictation is required — none, or the speech server's model + limits (Busyyaks::Dictation.parse!)
  def test_dictation_is_required_none_or_the_three_keys
    assert_nil Busyyaks::Config.new(OK).dictation
    on = { "model" => "whisper-1", "timeout_seconds" => 30, "max_seconds" => 120 }
    assert_equal 120, Busyyaks::Config.new(OK.merge("dictation" => on)).dictation.max_seconds
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("dictation")) }
    assert_match(/missing keys: dictation/, e.message)
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("dictation" => on.except("model"))) }
    assert_match(/dictation must be `none` or a mapping with exactly/, e.message)
  end

  # The skills bin/launcher hands each session are stated — limits, project skills, the deployment's dir
  def test_skills_are_required
    assert_equal ["allow", nil], Busyyaks::Config.new(OK).skills.to_h.values_at(:project, :local_dir)
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("skills")) }
    assert_match(/missing keys: skills/, e.message)
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("skills" => SKILLS_SETTINGS.except("project"))) }
    assert_match(/skills: missing project/, e.message)
  end

  # card #470: how the github service reads CI is stated — the stuck limit + the contexts that gate per repo, no default
  def test_ci_is_required_with_the_stuck_limit_and_the_required_contexts
    ci = Busyyaks::Config.new(OK).ci
    assert_equal [3600, ["jenkins/ci"], ["jenkins/ci"], nil],
                 [ci.max_pending_seconds, ci.required_for("o/r"), ci.required_for("O/R"), ci.required_for("o/x")]
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("ci")) }
    assert_match(/missing keys: ci/, e.message)
    [nil, "60", {}, { "max_pending_minutes" => 60 }, CI_SETTINGS.merge("x" => 1),
     CI_SETTINGS.merge("max_pending_minutes" => 0), CI_SETTINGS.merge("max_pending_minutes" => 1441),
     CI_SETTINGS.merge("max_pending_minutes" => 1.5), CI_SETTINGS.merge("required" => {}),
     CI_SETTINGS.merge("required" => { "o/r" => [] }), CI_SETTINGS.merge("required" => { "o/r" => "jenkins/ci" }),
     CI_SETTINGS.merge("required" => { "o/r" => [" "] }), CI_SETTINGS.merge("required" => { "r" => ["jenkins/ci"] }),
     CI_SETTINGS.merge("required" => { "o/r" => %w[a a] }),
     CI_SETTINGS.merge("required" => { "o/r" => ["a"], "O/r" => ["a"] }),].each do |bad|
      e = assert_raises(Busyyaks::Config::Invalid, bad.inspect) { Busyyaks::Config.new(OK.merge("ci" => bad)) }
      assert_match(/\Aci/, e.message)
    end
  end

  # the terminal is stated — public_host allow|deny + max_open 1..64 (Busyyaks::Terminal.parse!)
  def test_terminal_is_required_public_host_and_max_open
    t = Busyyaks::Config.new(OK).terminal
    assert_equal ["deny", 4, false], [t.public_host, t.max_open, t.public_allowed?]
    assert Busyyaks::Config.new(OK.merge("terminal" => { "public_host" => "allow", "max_open" => 64 })).terminal.public_allowed?
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("terminal")) }
    assert_match(/missing keys: terminal/, e.message)
    { "deny" => /must be a mapping with exactly public_host, max_open/,
      { "public_host" => "deny" } => /exactly public_host, max_open/,
      { "public_host" => "yes", "max_open" => 4 } => /public_host must be allow or deny/,
      { "public_host" => "deny", "max_open" => 0 } => /max_open must be an integer 1..64/,
      { "public_host" => "deny", "max_open" => "4" } => /max_open must be an integer 1..64/, }.each do |bad, msg|
      e = assert_raises(Busyyaks::Config::Invalid, bad.inspect) { Busyyaks::Config.new(OK.merge("terminal" => bad)) }
      assert_match msg, e.message
    end
  end

  # sign-in is chosen, never defaulted
  def test_auth_is_required_and_names_a_provider
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("auth")) }
    assert_match(/missing keys: auth/, e.message)
    [nil, "none", {}, { "provider" => "" }, { "issuer" => "x" }].each do |bad|
      assert_raises(Busyyaks::Config::Invalid, bad.inspect) { Busyyaks::Config.new(OK.merge("auth" => bad)) }
    end
    assert_equal({ "provider" => "x", "k" => 1 },
                 Busyyaks::Config.new(OK.merge("auth" => { "provider" => "x", "k" => 1 })).auth)
  end

  # the agent-session collector is stated, never defaulted: none, or its two host paths
  def test_agents_collector_is_required_and_stated
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("agents")) }
    assert_match(/missing keys: agents/, e.message)
    assert_nil Busyyaks::Config.new(OK).agent_collector
    paths = { "snapshot" => "/c/sessions.json", "read_socket" => "/c/read.sock", "tmux_timeout_seconds" => 5,
              "answer_timeout_seconds" => 30, }
    c = Busyyaks::Config.new(OK.merge("agents" => { "collector" => paths })).agent_collector
    assert_equal ["/c/sessions.json", "/c/read.sock", 5, 30],
                 [c.snapshot, c.read_socket, c.tmux_timeout_seconds, c.answer_timeout_seconds]
    bad_paths = [paths.except("read_socket"), paths.merge("snapshot" => "rel/s.json"), paths.merge("extra" => "/x"),
                 paths.except("tmux_timeout_seconds"), paths.except("answer_timeout_seconds"),
                 paths.merge("tmux_timeout_seconds" => 0), paths.merge("tmux_timeout_seconds" => 61),
                 paths.merge("tmux_timeout_seconds" => "5"),
                 # a send is 4 tmux calls: the launcher's answer deadline must be above 4 × the tmux one
                 paths.merge("answer_timeout_seconds" => 20), paths.merge("answer_timeout_seconds" => 2.5),]
    [nil, "none", {}, { "collector" => nil }, { "collector" => "off" }, { "collector" => "none", "x" => 1 },
     *bad_paths.map { { "collector" => _1 } },].each do |bad|
      assert_raises(Busyyaks::Config::Invalid, bad.inspect) { Busyyaks::Config.new(OK.merge("agents" => bad)) }
    end
  end

  # bin/launcher refuses to start on a collector path that is not there
  def test_collector_paths_must_exist_for_the_launcher
    Dir.mktmpdir do |d|
      snap = File.join(d, "sessions.json")
      sock = File.join(d, "read.sock")
      paths = Busyyaks::AgentCollector::Paths.new(snapshot: snap, read_socket: sock)
      e = assert_raises(Busyyaks::AgentCollector::Invalid) { Busyyaks::AgentCollector.check!(paths) }
      assert_match(/snapshot .* is not a file: start the collector, or set agents.collector: none/, e.message)
      File.write(snap, "{}")
      e = assert_raises(Busyyaks::AgentCollector::Invalid) { Busyyaks::AgentCollector.check!(paths) }
      assert_match(/read_socket .* is not a unix socket/, e.message)
      server = UNIXServer.new(sock)
      assert_nil Busyyaks::AgentCollector.check!(paths)
      server.close
    end
  end

  # collector none: exactly the ops that read it answer OFF (unsupported → the notifier fails the ping with the reason);
  # the tmux ops are never refused; a configured collector refuses nothing
  def test_collector_refusal_per_op
    c = Busyyaks::AgentCollector
    off = { ok: false, error: c::OFF, unsupported: true, status: 422 }
    %w[agents agent_tasks reap_preview reap notify].each { |op| assert_equal off, c.refusal(nil, op), op }
    %w[sessions name launch create jobs stop dialog git answer nope].each { |op| assert_nil c.refusal(nil, op), op }
    paths = c::Paths.new(snapshot: "/c/s.json", read_socket: "/c/r.sock")
    (c::OPS + %w[sessions dialog]).each { |op| assert_nil c.refusal(paths, op), op }
    assert_match(/stuck on a dialog before anyone comments/, c::OFF)
  end

  def test_shipped_example_has_no_sign_in
    ex = YAML.safe_load_file(File.expand_path("../../config/busyyaks.example.yml", __dir__))
    assert_equal({ "provider" => "none", "allow_unauthenticated" => true }, ex["auth"])
    # busyyaks ships its collector (card #479): the example runs bin/collector at its own private dir
    assert_equal({ "collector" => { "snapshot" => "/home/you/.local/state/busyyaks/collector/sessions.json",
                                    "read_socket" => "/home/you/.local/state/busyyaks/collector/read.sock",
                                    "tmux_timeout_seconds" => 5, "answer_timeout_seconds" => 30, } },
                 ex["agents"])
  end

  def test_missing_key_fails
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("roots")) }
    assert_match(/missing keys: roots/, e.message)
  end

  def test_unknown_key_fails
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("extra" => 1)) }
  end

  def test_bad_window_fails
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("window_days" => 0)) }
  end

  def test_bad_search_depth_fails
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("search_depth" => -1)) }
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("search_depth" => "2")) }
  end

  def test_root_without_prefix_fails
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("roots" => ["/p"])) }
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("roots" => [{ "path" => "/p" }])) }
  end

  def test_duplicate_prefix_fails
    r = [{ "path" => "/a", "prefix" => "" }, { "path" => "/b", "prefix" => "" }]
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("roots" => r)) }
  end

  def test_launchers_are_the_board_configs_not_this_one
    # a launch is defined ONCE, in config/kanban.yml (the engine's launchers) — a `launchers:` key here is refused
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("launchers" => [])) }
    assert_match(/unknown keys: launchers/, e.message)
  end

  # engines are config — absent = config/engines.yml alone; a deployment adds its own; a bad table fails at boot
  def test_engines_default_to_claude_and_take_custom_ones
    assert_equal %w[claude claudeapi localclaude hermes], Busyyaks::Config.new(OK).engines.names
    e = Busyyaks::Config.new(OK.merge("engines" => { "wrap" => { "label" => "Local", "family" => "claude" } })).engines
    assert_equal %w[claude claudeapi localclaude hermes wrap], e.names
    assert_equal %w[Local claude], [e.fetch("wrap").label, e.fetch("wrap").family.name]
    assert_match(/family hermes|unknown family "codex"/, assert_raises(Busyyaks::Config::Invalid) {
      Busyyaks::Config.new(OK.merge("engines" => { "x" => { "label" => "X", "family" => "codex" } }))
    }.message)
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("engines" => { "x" => { "label" => "X" } })) }
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("engines" => ["claude"])) }
  end

  def test_the_example_config_loads
    example = File.expand_path("../../config/busyyaks.example.yml", __dir__)
    assert_equal %w[claude claudeapi localclaude hermes claude-local], Busyyaks::Config.load(example).engines.names
  end

  # PROJECTS_MOUNT (.env) is the one place the container's mount point is set: a root outside it is refused at load
  def test_roots_must_lie_under_the_projects_mount
    example = File.expand_path("../../config/busyyaks.example.yml", __dir__)
    assert Busyyaks::Config.load(example, mount: "/projects")
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.load(example, mount: "/repos") }
    assert_equal "roots /projects not under PROJECTS_MOUNT /repos (where compose mounts PROJECTS_ROOT)", e.message
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK).roots_under!("/pp") }
    Busyyaks::Config.new(OK.merge("roots" => [{ "path" => "/p/a", "prefix" => "" }])).roots_under!("/p")
  end

  def test_missing_file_fails
    assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.load("/nope.yml") }
  end

  # how the daily report runs is a database revision (DailyReportSettings); the file keeps only the runners a
  # revision may pick (daily_report_runners) and refuses the old block
  def test_the_old_daily_report_key_is_refused
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("daily_report" => {})) }
    assert_match(/daily_report moved to the database: Settings → Daily report/, e.message)
    # the order that can run: the import reads daily_report_runners from this file, which does not load
    # while the old key is in it — so the key goes first, then the import
    steps = ["1. copy the daily_report block into a file;", "2. replace it here by daily_report_runners:",
             "3. `bin/daily-report-settings import < file`",]
    assert_operator steps.map { e.message.index(_1) }, :==, steps.map { e.message.index(_1) }.compact.sort
  end

  def test_daily_report_runners_are_optional_and_checked
    assert_equal [], Busyyaks::Config.new(OK).daily_report_runners
    ok = [{ "type" => "hermes", "command" => "hermes", "home" => "/h/.hermes-busyyaks" }]
    assert_equal ok, Busyyaks::Config.new(OK.merge("daily_report_runners" => ok)).daily_report_runners
    bad = {
      "must be a list" => { "type" => "hermes" },
      "is not a runner (known: hermes)" => [{ "type" => "codex" }],
      "must have exactly type, command, home" => [{ "type" => "hermes", "command" => "hermes" }],
      "[0] must have exactly" => [ok.first.merge("max_children" => 2)],
      "home must not contain control characters" => [ok.first.merge("home" => "/h\nX=1")],
      "command must be a non-empty string" => [ok.first.merge("command" => " ")],
      "duplicate entry" => ok + ok,
    }
    bad.each do |msg, v|
      e = assert_raises(Busyyaks::Config::Invalid, msg) { Busyyaks::Config.new(OK.merge("daily_report_runners" => v)) }
      assert_includes e.message, msg
    end
  end

  def test_every_runner_type_has_its_script
    Busyyaks::DailyReportConfig::RUNNERS.each_key do |t|
      assert File.executable?(File.expand_path("../../bin/daily-report-runners/#{t}", __dir__)), "bin/daily-report-runners/#{t}"
    end
  end

  def test_the_example_config_loads_with_a_daily_report_runner
    c = Busyyaks::Config.load(File.expand_path("../../config/busyyaks.example.yml", __dir__))
    assert_equal ["hermes"], c.daily_report_runners.map { _1["type"] }
  end

  # one owner_remotes rule for Config and the scanner (OwnerRemotes)
  def test_owner_remotes_use_the_shared_rule
    [[], [""], ["  "], "github.com/me/", [1]].each do |v|
      e = assert_raises(Busyyaks::Config::Invalid, v.inspect) { Busyyaks::Config.new(OK.merge("owner_remotes" => v)) }
      assert_match(/owner_remotes must be a non-empty list of non-empty strings/, e.message)
    end
    # an old substring-style entry can never match the anchored rule: refused, never silently owning nothing
    { ["your-user/"] => /names no host \+ owner/, ["."] => /names no host/, ["/"] => /names no host|empty/,
      ["github.com/"] => /names no host/, ["github.com/../x/"] => /empty, \. or \.\. segment/, ["github.com/%2e/"] => /holds %/,
      ["//home/x/"] => /"\/\/home\/x\/" has an empty, \. or \.\. segment \(e\.g\. a leading \/\/ or a path\)/,
      ["github.com/you?x/"] => /holds \? or \[/, ["github.com/[a-z]*/"] => /holds \? or \[/, }.each do |v, why|
      e = assert_raises(Busyyaks::Config::Invalid, v.inspect) { Busyyaks::Config.new(OK.merge("owner_remotes" => v)) }
      assert_match(why, e.message, v.inspect)
    end
    assert Busyyaks::Config.new(OK.merge("owner_remotes" => ["github.com/me/", "github.com:me/", "git.example/team"]))
  end

  # launch.trusted_paths (folder trust, LaunchTrust): required, absolute, under PROJECTS_MOUNT; no default
  def test_launch_trusted_paths_are_required_and_validated
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.except("launch")) }
    assert_match(/missing keys: launch/, e.message)
    [nil, {}, { "trusted_paths" => ["rel"] }, { "trusted_paths" => "/p" }].each do |v|
      assert_raises(Busyyaks::Config::Invalid, v.inspect) { Busyyaks::Config.new(OK.merge("launch" => v)) }
    end
    launch = LAUNCH_CLAUDE.merge("trusted_paths" => ["/p/a"])
    assert_equal ["/p/a"], Busyyaks::Config.new(OK.merge("launch" => launch)).trusted_paths
    Dir.mktmpdir do |d|
      f = File.join(d, "c.yml")
      File.write(f, YAML.dump(OK.merge("launch" => LAUNCH_CLAUDE.merge("trusted_paths" => ["/elsewhere/a"]))))
      e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.load(f, mount: "/p") }
      assert_match(/not under PROJECTS_MOUNT/, e.message)
    end
  end

  # launch.start_seconds: required, an integer 1..600, no default
  def test_launch_start_seconds_is_required_and_validated
    assert_equal 30, Busyyaks::Config.new(OK).launch_start_seconds
    [nil, "30", 30.0, 0, -1, 601, true].each do |v|
      launch = v.nil? ? LAUNCH_CLAUDE.except("start_seconds") : LAUNCH_CLAUDE.merge("start_seconds" => v)
      e = assert_raises(Busyyaks::Config::Invalid, v.inspect) { Busyyaks::Config.new(OK.merge("launch" => launch)) }
      assert_match(/launch.start_seconds must be an integer 1..600/, e.message, v.inspect)
    end
    [1, 600].each { |v| assert_equal v, Busyyaks::Config.new(OK.merge("launch" => LAUNCH_CLAUDE.merge("start_seconds" => v))).launch_start_seconds }
  end

  # launch.scopes: a required key — null, or the lead's oomd preference + the sessions' memory cap
  def test_launch_scopes_is_required_and_validated
    assert_nil Busyyaks::Config.new(OK).launch_scopes
    e = assert_raises(Busyyaks::Config::Invalid) { Busyyaks::Config.new(OK.merge("launch" => LAUNCH_CLAUDE.except("scopes"))) }
    assert_match(/launch.scopes is required/, e.message)
    good = { "lead_oomd" => "avoid", "session_memory_max" => "16G" }
    assert_equal good, Busyyaks::Config.new(OK.merge("launch" => LAUNCH_CLAUDE.merge("scopes" => good))).launch_scopes
    [{}, good.merge("x" => 1), good.merge("lead_oomd" => "omit"), good.merge("session_memory_max" => "16 GB"),
     good.merge("session_memory_max" => 16), "avoid",].each do |v|
      e = assert_raises(Busyyaks::Config::Invalid, v.inspect) do
        Busyyaks::Config.new(OK.merge("launch" => LAUNCH_CLAUDE.merge("scopes" => v)))
      end
      assert_match(/launch.scopes/, e.message)
    end
  end

  # launch.commands: the host allowlist of whole launcher invocations {kind, command, args, via_shell} —
  # required, non-empty, every key, unique; a bare command name is not an entry
  def test_launch_commands_are_required_and_validated
    trusted = { "trusted_paths" => [], "start_seconds" => 30, "scopes" => nil }
    claude = { "kind" => "claude_code", "command" => "claude", "args" => [], "via_shell" => false }
    bad = [nil, [], "claude", %w[claude], [claude, claude], [claude.except("args")], [claude.merge("kind" => "codex")],
           [claude.merge("command" => "claude; rm")], [claude.merge("args" => "--yolo")], [claude.merge("via_shell" => "no")],
           [claude.merge("extra" => 1)], [claude.merge("kind" => "hermes", "via_shell" => true)],]
    bad.each do |v|
      e = assert_raises(Busyyaks::Config::Invalid, v.inspect) { Busyyaks::Config.new(OK.merge("launch" => trusted.merge("commands" => v))) }
      assert_match(/launch.commands/, e.message)
    end
    hermes = { "kind" => "hermes", "command" => "hermes", "args" => ["chat"], "via_shell" => false }
    got = Busyyaks::Config.new(OK.merge("launch" => trusted.merge("commands" => [claude, hermes]))).launch_commands
    assert_equal [claude, hermes], got
  end
end
