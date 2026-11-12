# frozen_string_literal: true

require "test_helper"
require "busyyaks/setup_api"
require "busyyaks/github_network"

# the first-run hello screen — real boot checks, the projects dir read-only, the completion row.
class SetupAPITest < Minitest::Test
  include DBReset

  API = Busyyaks::SetupAPI

  Up = Struct.new(:list) do
    def sessions = list
  end

  class Down
    def sessions = raise(Busyyaks::LauncherClient::Unavailable, "launcher socket missing")
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
    assert_equal [false, "no GitHub collection has run yet (compose service github)"], c["github"].values_at(:ok, :detail)
  end

  def test_healthy_checks_carry_their_numbers
    now = Time.now.to_i
    db[:scans].insert(started_at: now - 5, finished_at: now - 1, repos: 7)
    db[:gh_runs].insert(login: ENV.fetch("GITHUB_LOGIN"), started_at: now - 9, finished_at: now - 2, ok: true,
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
    now = Time.now.to_i
    db[:scans].insert(started_at: now - 5, finished_at: now - 1, repos: 0, error: "root /projects missing")
    db[:gh_runs].insert(login: ENV.fetch("GITHUB_LOGIN"), started_at: now - 9, finished_at: now - 2, ok: false,
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
end
