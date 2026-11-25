# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "tmpdir"
require "socket"
require "busyyaks/git_hosts"
require_relative "../support/fake_github"

# Over HTTP: Settings → Git hosts reads the connection from the database and connects / disconnects through
# the github service's socket (a real GitHosts::Server here, GitHub faked) — the token never comes back.
class GitHostsApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  def app = Hanami.app

  def setup
    super
    @db = Hanami.app["db.gateway"].connection
    GitHostFixture.none!(@db)
    @dir = Dir.mktmpdir("git-hosts-api")
    @store = Busyyaks::GitHosts::Store.new(File.join(@dir, "secrets"))
    gh = FakeGithub.new
    gh.set("/user", { "login" => "octocat" })
    @sock = File.join(@dir, "gh.sock")
    @server = UNIXServer.new(@sock)
    Busyyaks::GitHosts::Server.new(db: @db, store: @store, socket: @server, http: gh).start
    @old_sock = ENV.fetch("GIT_HOSTS_SOCKET", nil)
    ENV["GIT_HOSTS_SOCKET"] = @sock
    sign_in
  end

  def teardown
    @server.close
    ENV["GIT_HOSTS_SOCKET"] = @old_sock
    FileUtils.rm_rf(@dir)
    super
  end

  def call(verb, body = nil)
    send(verb, "/api/settings/git-hosts", body && JSON.generate(body),
         { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json",
           "HTTP_X_CSRF_TOKEN" => shell_csrf_token, })
    [last_response.status, JSON.parse(last_response.body)]
  end

  def test_connect_show_disconnect
    status, body = call(:get)
    assert_equal [200, nil], [status, body["current"]]
    assert_equal [true, false], body["providers"].map { _1["available"] }

    status, body = call(:post, { provider: "github", token: "ghp_secret_wxyz" })
    assert_equal [200, "octocat", "…wxyz"], [status, body.dig("current", "login"), body.dig("current", "token_hint")]
    refute_includes last_response.body, "ghp_secret", "the token never comes back"
    assert_equal "ghp_secret_wxyz", @store.token("github")
    _, body = call(:get)
    assert_equal ["github", nil], [body.dig("current", "provider"), body["collector"]]

    status, body = call(:post, { provider: "gitlab", token: "x" })
    assert_equal [422, "GitLab is coming soon: it cannot be connected yet"], [status, body["error"]]

    assert_equal [200, { "current" => nil }], call(:delete)
    assert_nil Busyyaks::GitHosts.current(@db)
  end

  def test_a_down_github_service_is_503_and_changes_nothing
    ENV["GIT_HOSTS_SOCKET"] = File.join(@dir, "gone.sock")
    status, body = call(:post, { provider: "github", token: "t" })
    assert_equal 503, status
    assert_match(/github service is not running/, body["error"])
    assert_equal 503, call(:delete).first
    assert_nil Busyyaks::GitHosts.current(@db)
  end
end
