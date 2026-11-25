# frozen_string_literal: true

require "test_helper"
require "rack/test"
require_relative "../support/collector_sandbox"

# docs/USE-CASES-session-isolation.md, the web's side of U3 + U4 — what the live run checked in a browser on a local
# deployment, here with no browser, model or AI session: the web app (Rack::Test) talks to the REAL bin/launcher +
# bin/collector of a sandbox (test/support/collector_sandbox.rb: a stub tmux whose project `app` runs two sessions
# busyyaks launched, by_app_lead + by_desk, and `hand`, a claude the operator started from a terminal in the same
# directory).
class SessionIsolationTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn
  include CollectorSandbox

  def app = Hanami.app

  def setup
    super
    sandbox_up!
    @socket_was = ENV.fetch("LAUNCHER_SOCKET")
    ENV["LAUNCHER_SOCKET"] = launcher_socket
    Busyyaks::LauncherClient.forget_agents_snapshot!
    store.upsert_project(slug: "app", path: "/projects/app", remote: nil, branch: "main", own: true,
                         last_commit_at: Busyyaks::Clock.epoch, commits_window: 1, mine_window: 1, dirty: 0,
                         unpushed: nil, scanned_at: 1)
    assert_equal 200, sign_in
    @csrf = shell_csrf_token
  end

  def teardown
    ENV["LAUNCHER_SOCKET"] = @socket_was
    Busyyaks::LauncherClient.forget_agents_snapshot!
    sandbox_down!
    super
  end

  def api(verb, path, body = nil)
    send(verb, path, body && JSON.generate(body),
         "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "HTTP_X_CSRF_TOKEN" => @csrf)
    JSON.parse(last_response.body)
  end

  def tmux_calls = File.read(File.join(@base, "tmux.log"))

  # U4, the operator: "It must not appear in working agents if it's not run by busyyaks". The Agents sidebar's API
  # (live run: "3 sessions", the hand-run one not among them) lists the sessions busyyaks launched only
  def test_a_session_started_from_the_terminal_is_not_in_the_agents_sidebar
    j = api(:get, "/api/agents")
    assert_equal 200, last_response.status, j.inspect
    names = j["groups"].flat_map { |g| g["sessions"] }.map { |s| s["name"] }
    assert_equal %w[by_app_lead by_desk], names.sort
    assert_equal 2, j.dig("totals", "sessions")
    refute_includes last_response.body, '"hand"'
  end

  # U4: the project page's session list (its chips) and the card owner picker come from
  # the same launcher answer — the hand-run session is in none of them
  def test_the_project_page_lists_no_session_started_from_the_terminal
    j = api(:get, "/api/projects/app/sessions")
    assert_equal 200, last_response.status, j.inspect
    assert_equal %w[by_app_lead by_desk], j["sessions"].map { |s| s["name"] }.sort
    assert_nil j["launcher_error"]
    assignees = api(:get, "/api/projects/app/board")["assignees"]
    assert_includes assignees, "by_app_lead"
    refute_includes assignees, "hand", "never offered as a card's owner"
  end

  # U4, the live run's Stop: the web's Stop for a session started by hand answers "not started by busyyaks" (never
  # "not running", never stopped) and the session keeps running — no kill-session, no key, nothing typed
  def test_stop_answers_not_started_by_busyyaks_for_a_session_started_from_the_terminal_and_it_keeps_running
    j = api(:post, "/api/projects/app/stop", { sessions: %w[hand] })
    assert_equal 200, last_response.status, j.inspect
    assert_equal [{ "name" => "hand", "stopped" => false, "reason" => "not started by busyyaks" }], j["results"]
    refute_match(/kill-session|send-keys/, tmux_calls)
    refute File.exist?(File.join(@base, "inputs")), "nothing typed into it"
    # it keeps running: its pane's process (the stub claude `hand` runs in) is alive after the Stop — not exited, not
    # a zombie (no kill-session reached tmux, and nothing signalled the process itself)
    assert_nil Process.waitpid(@agent, Process::WNOHANG), "the hand-run session's process has not exited"
    assert_equal 1, Process.kill(0, @agent)
  end

  # U3, the operator: "Add naming to the busyyaks sessions … start with BY so we can easily identify and isolate them" —
  # Settings → Agents & launchers refuses a session_name without the prefix (422, nothing written)
  def test_agent_settings_refuse_a_session_name_without_by_through_the_web_api
    shown = api(:get, "/api/settings/agents")
    assert_equal 200, last_response.status
    doc = shown["doc"]
    doc["agent_types"].find { |t| t["key"] == "team" }["session_name"] = "{slug}_team"
    n = Hanami.app["db.gateway"].connection[:agent_settings].count
    j = api(:post, "/api/settings/agents", { base: shown.dig("revision", "id"), doc: doc })
    assert_equal 422, last_response.status, j.inspect
    assert_equal 'agent type team: session_name "{slug}_team" must start with "by_" — every session busyyaks starts is ' \
                 "named so, and busyyaks touches no tmux session without it", j["error"]
    assert_equal n, Hanami.app["db.gateway"].connection[:agent_settings].count, "nothing written"
  end
end
