# frozen_string_literal: true

require "test_helper"
require "busyyaks/setup_api"
require "busyyaks/github_network"

# the first-run hello screen — real boot checks, the projects dir (changed through bin/launcher), the completion row.
class SetupAPITest < Minitest::Test
  include DBReset

  API = Busyyaks::SetupAPI

  # what bin/launcher's harnesses op answers (JSON round-tripped: string keys)
  PROBE = {
    "ok" => true, "shell" => "bash -ic",
    "harnesses" => [
      { "key" => "claude", "label" => "Claude Code", "command" => "claude", "kind" => "claude_code", "launch_args" => [],
        "install_url" => "https://c.example", "found" => true, "type" => "file", "path" => "/u/bin/claude",
        "version" => "2.1.3", "version_error" => nil, },
      { "key" => "hermes", "label" => "Hermes Agent", "command" => "hermes", "kind" => "hermes", "launch_args" => ["chat"],
        "install_url" => "https://h.example", "found" => false, "type" => nil, "path" => nil, "version" => nil,
        "version_error" => nil, },
      { "key" => "codex", "label" => "Codex CLI", "command" => "codex", "kind" => nil, "launch_args" => [],
        "install_url" => "https://x.example", "found" => true, "type" => "file", "path" => "/u/bin/codex", "version" => nil,
        "version_error" => "timed out after 5 s", },
    ],
    "commands" => [{ "command" => "claude", "found" => true, "type" => "file", "path" => "/u/bin/claude" },
                   { "command" => "fullclaude", "found" => true, "type" => "function", "path" => nil },],
    "allowlist" => [{ "kind" => "claude_code", "command" => "claude", "args" => [], "via_shell" => false },
                    { "kind" => "claude_code", "command" => "fullclaude", "args" => [], "via_shell" => true },],
  }.freeze

  Up = Struct.new(:list) do
    def sessions = list
    def harnesses = PROBE
  end

  class Down
    def sessions = raise(Busyyaks::LauncherClient::Unavailable, "launcher socket missing")
    def harnesses = raise(Busyyaks::LauncherClient::Unavailable, "launcher socket missing")
  end

  def db = Hanami.app["db.gateway"].connection
  def github = Busyyaks::GithubNetwork::Data.new(db)

  def show(launcher: Up.new([{ "name" => "a" }, { "name" => "b" }]))
    API.show(db: db, store: store, config: Busyyaks::Config.load, github: github, launcher: launcher)
  end

  def checks(body) = body[:checks].to_h { |c| [c[:key], c] }

  def test_a_fresh_install_is_pending_and_every_check_says_why_it_fails
    status, body = show(launcher: Down.new)
    assert_equal 200, status
    assert_nil body[:completed]
    refute API.completed?(db)
    c = checks(body)
    assert_equal %w[database scanner launcher agents github], body[:checks].map { |x| x[:key] }
    assert c["database"][:ok]
    assert_equal [false, "no scan has finished yet (compose service scanner)"], c["scanner"].values_at(:ok, :detail)
    assert_equal [false, "launcher socket missing"], c["launcher"].values_at(:ok, :detail)
    assert c["agents"][:ok], c["agents"].inspect
    assert_equal [false, "no GitHub collection has run yet for octotest (compose service github)"],
                 c["github"].values_at(:ok, :detail)
  end

  def test_healthy_checks_carry_their_numbers
    now = Busyyaks::Clock.epoch
    db[:scans].insert(started_at: now - 5, finished_at: now - 1, repos: 7)
    db[:gh_runs].insert(login: GitHostFixture::LOGIN, started_at: now - 9, finished_at: now - 2, ok: true,
                        baseline: false)
    c = checks(show.last)
    assert_equal [true, true, true], [c["scanner"][:ok], c["launcher"][:ok], c["github"][:ok]]
    assert_match(/\A7 repos · finished /, c["scanner"][:detail])
    assert_equal "2 tmux sessions", c["launcher"][:detail]
    assert_match(/\A2 launchers · \d+ agent types · revision \d+\z/, c["agents"][:detail])
    assert_equal "1 tmux session", checks(show(launcher: Up.new([{ "name" => "a" }])).last)["launcher"][:detail]
    assert_equal "1 launcher", API.count(1, "launcher")
  end

  def test_a_failed_scan_and_a_failed_github_run_are_shown_as_failed
    now = Busyyaks::Clock.epoch
    db[:scans].insert(started_at: now - 5, finished_at: now - 1, repos: 0, error: "root /projects missing")
    db[:gh_runs].insert(login: GitHostFixture::LOGIN, started_at: now - 9, finished_at: now - 2, ok: false,
                        baseline: false, error: "401 bad credentials")
    c = checks(show.last)
    assert_equal [false, "last scan failed: root /projects missing"], c["scanner"].values_at(:ok, :detail)
    assert_equal [false, "401 bad credentials"], c["github"].values_at(:ok, :detail)
  end

  def test_projects_are_the_host_dir_and_the_roots_read_only
    p = show.last[:projects]
    assert_equal ENV.fetch("PROJECTS_ROOT"), p[:host_root]
    assert_equal ENV.fetch("PROJECTS_MOUNT"), p[:mount]
    assert_equal Busyyaks::Config.load.roots, p[:roots]
    assert_equal 0, p[:repos]
  end

  def test_the_agent_settings_are_the_settings_pages_read
    body = show.last
    assert_equal Busyyaks::AgentSettingsAPI.show(db: db, commands: Busyyaks::Config.load.launch_commands).last, body[:agents]
  end

  def test_complete_records_who_and_the_newest_row_is_shown
    deps = { db: db, store: store, config: Busyyaks::Config.load, github: github, launcher: Up.new([]) }
    assert_raises(ArgumentError) { API.complete(by: "", **deps) }
    refute API.completed?(db), "nobody named: nothing written"
    _, body = API.complete(by: "op", **deps)
    assert_equal "op", body[:completed][:author]
    assert API.completed?(db)
    API.complete(by: "op2", **deps)
    assert_equal "op2", API.completed(db)[:author]
  end

  COMMANDS = [{ "kind" => "claude_code", "command" => "claude", "args" => [], "via_shell" => false },
              { "kind" => "claude_code", "command" => "fullclaude", "args" => [], "via_shell" => true },].freeze

  class Fake
    def initialize(&blk) = @blk = blk
    def harnesses = @blk.call
  end

  # each harness the launcher found, joined with this host's allowlist
  def test_harnesses_carry_the_allowlist_and_the_line_to_add
    status, body = API.harnesses(launcher: Up.new([]), commands: COMMANDS)
    assert_equal 200, status
    c, he, x = body[:harnesses]
    assert_equal [true, [0, 1], "- { kind: claude_code, command: claude, args: [], via_shell: false }", "2.1.3"],
                 c.values_at(:launchable, :allowed, :allow_line, :version)
    assert_equal [true, false, [], "- { kind: hermes, command: hermes, args: [chat], via_shell: false }"],
                 he.values_at(:launchable, :found, :allowed, :allow_line)
    assert_equal [false, [], nil, "timed out after 5 s"], x.values_at(:launchable, :allowed, :allow_line, :version_error)
    assert_nil c[:allow_note]
  end

  # a harness found only as a shell function / alias: its line runs it through the shell, where the kind allows that
  def test_the_line_for_a_shell_function_says_via_shell_or_why_none
    fn = ->(key, kind, args) {
      PROBE["harnesses"].find { |h| h["key"] == key }.merge("kind" => kind, "found" => true, "type" => "function",
                                                            "path" => nil, "launch_args" => args)
    }
    probe = PROBE.merge("harnesses" => [fn.("claude", "claude_code", []), fn.("hermes", "hermes", ["chat"])])
    _, body = API.harnesses(launcher: Fake.new { probe }, commands: COMMANDS)
    c, he = body[:harnesses]
    assert_equal "- { kind: claude_code, command: claude, args: [], via_shell: true }", c[:allow_line]
    assert_equal [nil, "hermes is a shell function: hermes needs a program on PATH to launch"],
                 he.values_at(:allow_line, :allow_note)
    assert_equal [{ at: 0, found: true, type: "file", path: "/u/bin/claude" },
                  { at: 1, found: true, type: "function", path: nil },], body[:commands]
    assert_equal "bash -ic", body[:shell]
    assert body[:allowlist_in_sync]
    # the launcher read another launch.commands than this process (one of them started before an edit): said
    _, stale = API.harnesses(launcher: Fake.new { PROBE.merge("allowlist" => [COMMANDS.first]) }, commands: COMMANDS)
    refute stale[:allowlist_in_sync]
    assert_kind_of Integer, body[:checked_at]
  end

  def test_a_launcher_that_cannot_answer_is_said_never_guessed
    assert_equal [503, { error: "launcher socket missing" }], API.harnesses(launcher: Down.new, commands: COMMANDS)
    old = Fake.new { raise Busyyaks::LauncherClient::Refused, "unknown op" }
    status, body = API.harnesses(launcher: old, commands: COMMANDS)
    assert_equal 501, status
    assert_match(/restart it/, body[:error])
    failed = Fake.new { raise Busyyaks::LauncherClient::Refused, "harness probe: bash -ic timed out after 8 s" }
    assert_equal [500, { error: "harness probe: bash -ic timed out after 8 s" }],
API.harnesses(launcher: failed, commands: COMMANDS)
    # a launcher started before an allowlist edit did not resolve the new command: unknown, out of sync — never "not found"
    stale = Fake.new { PROBE.merge("commands" => [PROBE["commands"].first]) }
    status, body = API.harnesses(launcher: stale, commands: COMMANDS)
    assert_equal 200, status
    assert_equal({ at: 1, found: nil, type: nil, path: nil }, body[:commands].last)
    refute body[:allowlist_in_sync]
  end

  def test_show_carries_the_kind_labels
    assert_equal({ "claude_code" => "Claude Code", "hermes" => "Hermes Agent" }, show.last[:kinds])
  end

  def test_show_carries_the_daily_report_state
    assert_equal [false, false], show.last[:daily_report].values_at(:configured, :saved)
    assert_match(/no daily report settings saved/, show.last[:daily_report][:reason])
  end
  # the projects dir (card 532): bin/launcher's answers relayed with its status; a launcher down is 503
  Root = Struct.new(:answer) do
    def browse(path:) = answer.merge("path" => path)
    def projects_root(step:, path:, plan_id:) = answer.merge("seen" => [step, path, plan_id])
  end

  def test_the_projects_dir_relays_the_launchers_answer_and_status
    assert_equal [200, { "path" => "/srv", "entries" => [] }],
                 API.browse(path: "/srv", launcher: Root.new({ "ok" => true, "entries" => [] }))
    assert_equal [200, { "plan" => 1, "seen" => ["plan", "/srv", nil] }],
                 API.projects_root(step: "plan", path: "/srv", launcher: Root.new({ "ok" => true, "plan" => 1 }))
    assert_equal [409, { error: "the plan changed" }],
                 API.projects_root(step: "apply", path: "/srv", plan_id: "x",
                                   launcher: Root.new({ "ok" => false, "error" => "the plan changed", "status" => 409 }))
    assert_equal [422, { error: "no" }],
                 API.browse(path: "/", launcher: Root.new({ "ok" => false, "error" => "no", "status" => 422 }))
    # a refusal with no status (an older launcher's "unknown op") is never given one
    assert_equal [503, { error: "launcher protocol error (unknown op): restart it (deploy/install-launcher.sh)" }],
                 API.browse(path: "/", launcher: Root.new({ "ok" => false, "error" => "unknown op" }))
  end

  def test_the_projects_dir_with_the_launcher_down_is_503
    down = Object.new
    def down.projects_root(**) = raise(Busyyaks::LauncherClient::Unavailable, "launcher socket missing")
    assert_equal [503, { error: "launcher socket missing" }], API.projects_root(step: "status", launcher: down)
  end
end
