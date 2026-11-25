# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "socket"
require "busyyaks/git_hosts"
require "busyyaks/git_hosts_api"
require "busyyaks/pr_states"
require "busyyaks/setup_api"
require "busyyaks/ci_checks"
require "busyyaks/github_pollers"
require "busyyaks/ci_settings"
require "minitest/mock"
require_relative "../support/fake_github"

# The git host is optional and set in the app — the connection (login) a database row, the token a file only
# the github service holds, connected through that service's socket. Nothing connected is a state every surface says.
class GitHostsTest < Minitest::Test
  include DBReset
  H = Busyyaks::GitHosts

  def setup
    super
    @db = Hanami.app["db.gateway"].connection
    @dir = Dir.mktmpdir("git-hosts")
    @store = H::Store.new(File.join(@dir, "secrets"))
    @gh = FakeGithub.new
    @gh.set("/user", { "login" => "octocat" })
    GitHostFixture.none!(@db)
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def connect(token = "ghp_secret_abcd", provider: "github")
    H.connect!(db: @db, store: @store, provider: provider, token: token, author: "op", http: @gh)
  end

  def test_nothing_is_connected_until_a_token_is
    assert_nil H.current(@db)
    assert_nil H.github_login(@db)
    assert_equal "GitHub not connected — Settings → Git hosts", H.not_connected
  end

  def test_connect_checks_the_token_with_github_and_keeps_it_only_in_the_store
    cur = connect
    assert_equal %w[github octocat …abcd op], cur.values_at(:provider, :login, :token_hint, :author)
    assert_equal "octocat", H.github_login(@db)
    assert_equal "ghp_secret_abcd", @store.token("github")
    assert_equal 0o600, File.stat(@store.path("github")).mode & 0o777
    assert_equal 0o700, File.stat(File.join(@dir, "secrets")).mode & 0o777
    row = @db[:git_host_connections].order(Sequel.desc(:id)).first
    refute_includes row.values.map(&:to_s).join(" "), "ghp_secret", "the token never reaches the database"
    assert_equal "https://api.github.com/user", @gh.requests.last.first
  end

  def test_a_token_github_rejects_changes_nothing
    @gh.fail_with = [401, "Bad credentials"]
    e = assert_raises(H::Refused) { connect }
    assert_match(/GitHub refused the token: GitHub rejected the token \(401\): Bad credentials/, e.message)
    assert_nil H.current(@db)
    assert_nil @store.token("github")
    assert_raises(H::Refused) { connect("  ") }
  end

  # a GitHub that cannot be asked says nothing about the token: 503 "could not check", never "refused"
  def test_github_down_or_rate_limited_is_unreachable_not_refused
    [[503, "Service Unavailable"], [403, "API rate limit exceeded"]].each do |fail|
      @gh.fail_with = fail
      e = assert_raises(H::Unreachable) { connect }
      assert_match(/\AGitHub could not check the token: GitHub (503|rate limited)/, e.message)
    end
    server = H::Server.new(db: @db, store: @store, socket: nil, http: @gh)
    answer = JSON.parse(server.handle(JSON.generate(op: "connect", provider: "github", token: "ghp_x", by: "op")))
    assert_equal 503, answer["status"]
    assert_nil H.current(@db)
    assert_nil @store.token("github")
  end

  # the row is what says "connected": a row that cannot be written puts the token file back as it was
  def test_a_failed_record_rolls_the_token_file_back
    connect("ghp_first_1111")
    H.stub(:record!, ->(*, **) { raise "db down" }) do
      assert_raises(RuntimeError) { connect("ghp_second_2222") }
    end
    assert_equal "ghp_first_1111", @store.token("github")
    H.disconnect!(db: @db, store: @store, author: "op")
    H.stub(:record!, ->(*, **) { raise "db down" }) { assert_raises(RuntimeError) { connect } }
    assert_nil @store.token("github"), "nothing was there before: nothing is left"
    assert_empty Dir.children(File.join(@dir, "secrets")), "no temp file left"
  end

  # Test connection: the stored token asked again; nothing written
  def test_test_asks_the_stored_token_again
    assert_raises(H::Refused) { H.test!(db: @db, store: @store, http: @gh) }
    connect
    assert_equal({ ok: true, login: "octocat", same: true }, H.test!(db: @db, store: @store, http: @gh))
    @gh.set("/user", { "login" => "someone" })
    assert_equal({ ok: true, login: "someone", same: false }, H.test!(db: @db, store: @store, http: @gh))
    assert_equal 1, @db[:git_host_connections].count, "a test writes nothing"
    @store.remove!("github")
    e = assert_raises(H::Refused) { H.test!(db: @db, store: @store, http: @gh) }
    assert_match(/token file is missing/, e.message)
  end

  def test_the_provider_collects_and_polls_and_gitlab_neither
    gitlab = H.provider!("gitlab")
    assert_raises(H::Refused) { gitlab.collect(db: @db, login: "x", token: "t", since: Date.new(2026, 11, 25)) }
    assert_raises(H::Refused) { gitlab.poll(db: @db, token: "t", gate: nil, interval: 60, ci: nil) }
    gh = H.provider!("github", http: @gh)
    @gh.set("/users/octocat", { "login" => "octocat" })
    out = gh.collect(db: @db, login: "octocat", token: "t", since: Date.new(2026, 11, 18))
    assert_equal %i[network prs], out.keys
    assert_equal 1, @db[:gh_runs].where(login: "octocat").count, "the network collector ran for the login"
    gate = Busyyaks::GithubPollers.new(db: @db)
    ci = Busyyaks::CiSettings.parse!("max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] })
    assert_equal({ polled: 0, failed: [] }, gh.poll(db: @db, token: "t", gate: gate, interval: 60, ci: ci),
                 "nothing asked: nothing polled")
    # one part failing never blanks the other, and the tick's cost is still recorded
    finished = 0
    counting = Object.new
    counting.define_singleton_method(:finished) { |_| finished += 1 }
    counting.define_singleton_method(:paused) { nil }
    Busyyaks::CiChecks::Poller.stub(:new, ->(**) { raise "db gone" }) do
      out = gh.poll(db: @db, token: "t", gate: counting, interval: 60, ci: ci)
      assert_equal ["ci checks: RuntimeError: db gone"], out[:failed]
    end
    assert_equal 1, finished
  end

  def test_gitlab_is_listed_and_coming_soon
    assert_equal [{ key: "github", label: "GitHub", available: true, note: nil },
                  { key: "gitlab", label: "GitLab", available: false, note: "coming soon" },], H.listing
    e = assert_raises(H::Refused) { connect(provider: "gitlab") }
    assert_equal "GitLab is coming soon: it cannot be connected yet", e.message
    assert_raises(H::Refused) { connect(provider: "bitbucket") }
    assert_nil H.current(@db)
  end

  def test_disconnect_removes_the_token_and_records_none
    connect
    H.disconnect!(db: @db, store: @store, author: "op")
    assert_nil H.current(@db)
    assert_nil @store.token("github")
    refute File.exist?(@store.path("github"))
    assert_equal 2, @db[:git_host_connections].count, "every change stays as history"
  end

  def test_the_socket_connects_and_disconnects_and_refuses_with_its_reason
    path = File.join(@dir, "gh.sock")
    server = UNIXServer.new(path)
    H::Server.new(db: @db, store: @store, socket: server, http: @gh).start
    ENV["GIT_HOSTS_SOCKET"] = path
    status, body = H::Client.connect("github", "ghp_secret_abcd", by: "op")
    assert_equal [200, "octocat"], [status, body["current"]["login"]]
    assert_equal [200, { "ok" => true, "login" => "octocat", "same" => true }], H::Client.test(by: "op")
    status, body = H::Client.connect("gitlab", "x", by: "op")
    assert_equal [422, "GitLab is coming soon: it cannot be connected yet"], [status, body["error"]]
    assert_equal [200, { "current" => nil }], H::Client.disconnect(by: "op")
    assert_equal 400, H::Client.call({ op: "connect", provider: "github", token: "t" }).first, "who acts is required"
  ensure
    server&.close
    ENV.delete("GIT_HOSTS_SOCKET")
  end

  def test_the_api_relays_a_down_service_as_503_and_shows_the_connection
    ENV["GIT_HOSTS_SOCKET"] = File.join(@dir, "none.sock")
    status, body = Busyyaks::GitHostsAPI.connect({ "provider" => "github", "token" => "t" }, by: "op")
    assert_equal 503, status
    assert_match(/github service is not running \(.* missing\): start it/, body[:error])
    assert_equal 422, Busyyaks::GitHostsAPI.connect("nope", by: "op").first
    _, show = Busyyaks::GitHostsAPI.show(db: @db)
    assert_nil show[:current]
    assert_equal %w[github gitlab], show[:providers].map { _1[:key] }
    connect
    @db[:gh_runs].insert(login: "octocat", started_at: 1, finished_at: 2, ok: false, error: "GitHub unreachable")
    _, show = Busyyaks::GitHostsAPI.show(db: @db)
    assert_equal "octocat", show[:current][:login]
    assert_equal({ ok: false, error: "GitHub unreachable", at: 2 }, show[:collector])
  ensure
    ENV.delete("GIT_HOSTS_SOCKET")
  end

  def test_the_socket_answers_a_bad_request_and_a_failure_with_their_reason
    server = H::Server.new(db: @db, store: @store, socket: nil, http: @gh, log: ->(l) { (@logged ||= []) << l })
    assert_equal({ "status" => 400, "body" => { "error" => "the request is not an object" } }, JSON.parse(server.handle("[1]")))
    assert_match(/not JSON/, JSON.parse(server.handle("{")).dig("body", "error"))
    assert_equal 400, JSON.parse(server.handle(JSON.generate(op: "x", by: "op")))["status"]
    broken = H::Store.new("/proc/forbidden") # a token file that cannot be written: 500, said and logged
    server = H::Server.new(db: @db, store: broken, socket: nil, http: @gh, log: ->(l) { (@logged ||= []) << l })
    answer = JSON.parse(server.handle(JSON.generate(op: "connect", provider: "github", token: "ghp_x", by: "op")))
    assert_equal 500, answer["status"]
    assert_match(/request failed/, @logged.last)
    assert_nil H.current(@db), "nothing recorded when the token could not be stored"
  end

  # the request line has ONE deadline: half a line, or nothing, never holds the thread; a whole line is read in pieces
  def test_the_server_reads_the_request_line_against_one_deadline
    server = H::Server.new(db: @db, store: @store, socket: nil, http: @gh)
    pairs = Array.new(3) { UNIXSocket.pair }
    a, b = pairs[0]
    a.write('{"op":"x"')
    assert_nil server.read_line(b, timeout: 0.05), "half a line: given up at the deadline"
    a, b = pairs[1]
    a.write('{"op":"x"')
    a.write(%(,"by":"op"}\nrest))
    assert_equal '{"op":"x","by":"op"}', server.read_line(b, timeout: 0.05)
    a, b = pairs[2]
    a.write("{")
    a.close
    assert_nil server.read_line(b, timeout: 0.05), "closed before a whole line"
  ensure
    pairs&.flatten&.each { _1.close unless _1.closed? }
  end

  def test_a_socket_that_never_answers_is_no_answer
    path = File.join(@dir, "mute.sock")
    mute = UNIXServer.new(path)
    ENV["GIT_HOSTS_SOCKET"] = path
    e = assert_raises(H::Client::NoAnswer) { H::Client.call({ op: "disconnect", by: "op" }, timeout: 0.05) }
    assert_match(/did not answer/, e.message)
    assert_equal 504, Busyyaks::GitHostsAPI.relay { raise H::Client::NoAnswer, "x" }.first
  ensure
    mute&.close
    ENV.delete("GIT_HOSTS_SOCKET")
  end

  def test_the_setup_check_calls_github_optional_until_it_is_connected
    data = Busyyaks::GithubNetwork::Data.new(@db)
    check = Busyyaks::SetupAPI.github_check(data, {})
    assert_equal [true, "GitHub not connected — Settings → Git hosts (optional)"], check.values_at(:ok, :detail)
  end

  # a PR flag never says "checking" when nothing could ever answer
  def test_pr_flags_say_github_is_not_connected
    reader = Busyyaks::PrStates::Reader.new(db: @db, stale_after: 180, wanted_for: 600)
    assert_equal({ error: "GitHub not connected — Settings → Git hosts" }, reader.lookup("o/r", "pr:1"))
    assert_equal 0, @db[:gh_pr_states].count, "nothing is asked of a collector that does not run"
  end
end
