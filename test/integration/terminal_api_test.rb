# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "tmpdir"
require "fileutils"
require "socket"
require "base64"
require "busyyaks/kanban"

# The terminal routes inside the app: /api/terminal is mounted behind HostGuard and refuses before any
# upgrade (signed out 401, PUBLIC_HOST with terminal.public_host: deny 403 — the suite's config), and
# GET /api/cards/:id/terminals lists the card's agent sessions with their live state (the launcher down said, never
# "not running").
class TerminalApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  def app = Hanami.app
  def kb = Busyyaks::Kanban.default

  def setup
    super
    @dir = Dir.mktmpdir
    store.upsert_project(slug: "g/r", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  WS = { "HTTP_UPGRADE" => "websocket", "HTTP_CONNECTION" => "Upgrade", "HTTP_SEC_WEBSOCKET_VERSION" => "13",
         "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce"),
         "HTTP_ORIGIN" => "https://example.org", }.freeze

  def test_terminal_refuses_signed_out_and_through_the_public_host_when_denied
    get "/api/terminal?session=lead_x", {}, WS
    assert_equal [401, "not signed in"], [last_response.status, JSON.parse(last_response.body)["error"]]
    assert_equal 200, sign_in
    get "/api/terminal?session=lead_x", {}, WS
    assert_equal 403, last_response.status
    assert_match(/not offered through example.org/, JSON.parse(last_response.body)["error"])
    get "/api/terminal?session=lead_x", {}, WS.merge("HTTP_ORIGIN" => "https://evil.example")
    assert_equal 403, last_response.status
    get "/api/terminal?session=lead_x", {}, { "HTTP_HOST" => "evil.example" }.merge(WS)
    assert_equal 421, last_response.status, "HostGuard runs first"
  end

  def test_card_terminals_lists_the_owner_and_the_assignees_sessions
    id = kb.create(slug: "g/r", title: "t", by: "op", column: "doing")
    assert_equal 200, sign_in
    get "/api/cards/#{id}/terminals"
    assert_equal({ "sessions" => [], "sessions_error" => JSON.parse(last_response.body)["sessions_error"] },
                 JSON.parse(last_response.body))
    kb.register_session(session: "lead_x", project: "g/r", type: "plain", launcher: "fullclaude", by: "op")
    kb.set_owner(id, session: "lead_x", by: "op")
    get "/api/cards/#{id}/terminals"
    j = JSON.parse(last_response.body)
    assert_equal [["lead_x", "default", "plain", true, nil]],
                 j["sessions"].map { |s| s.values_at("session", "socket", "type", "owner", "live") }
    assert_match(/launcher not reachable/, j["sessions_error"], "launcher down: live unknown, said")
    with_sessions(%w[lead_x other]) do
      get "/api/cards/#{id}/terminals"
      j = JSON.parse(last_response.body)
      assert_equal [true, nil], [j["sessions"].first["live"], j["sessions_error"]]
    end
    get "/api/cards/999999/terminals"
    assert_equal 422, last_response.status
  end

  def with_sessions(names)
    sock = ENV.fetch("LAUNCHER_SOCKET")
    File.unlink(sock) if File.socket?(sock)
    server = UNIXServer.new(sock)
    t = Thread.new do
      loop do
        c = server.accept
        c.gets
        c.puts JSON.generate(ok: true, sessions: names.map { |n| { name: n } })
        c.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield
  ensure
    server&.close
    t&.kill
    File.unlink(sock) if sock && File.socket?(sock)
  end
end
