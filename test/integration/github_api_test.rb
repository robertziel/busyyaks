# frozen_string_literal: true

require "test_helper"
require "rack/test"

# GET /api/github (the /github page's data) and the CSP that lets GitHub avatars — and only them — load.
class GithubApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  def app = Hanami.app
  def db = Hanami.app["db.gateway"].connection

  def get_json(path)
    get path, nil, { "HTTP_ACCEPT" => "application/json" }
    JSON.parse(last_response.body)
  end

  def test_signed_out_is_401
    get_json("/api/github?hours=24")
    assert_equal 401, last_response.status
  end

  def test_feed_with_rendered_lists
    sign_in
    now = Time.now.to_i
    login = ENV.fetch("GITHUB_LOGIN")
    db[:gh_runs].insert(login: login, started_at: now - 20, finished_at: now - 10, ok: true, baseline: true)
    db[:gh_follows].insert(follower: login, followee: "alice", first_seen_at: now, last_seen_at: now, baseline: true)
    db[:gh_users].insert(login: "alice", avatar_url: "https://avatars.githubusercontent.com/u/2?v=4")
    db[:gh_repos].insert(full_name: "o/r", html_url: "https://github.com/o/r", fetched_at: now)
    db[:gh_stars].insert(login: "alice", repo: "o/r", starred_at: now - 60, first_seen_at: now)
    out = get_json("/api/github?hours=24")
    assert_equal 200, last_response.status, out.inspect
    assert_equal ["o/r"], out["repos"].map { |r| r["repo"] }
    assert_equal true, out.dig("status", "ok")
    assert_includes out.dig("html", "repos"), %(href="https://github.com/o/r")
    assert_equal "", out.dig("html", "people")
    assert_equal ["alice"], out["followees"].map { |f| f["login"] }
  end

  def test_bad_hours_is_400
    sign_in
    assert_match(/hours must be/, get_json("/api/github?hours=abc")["error"])
    assert_equal 400, last_response.status
    get_json("/api/github?hours=9999")
    assert_equal 400, last_response.status
  end

  def test_csp_allows_github_avatars_only
    sign_in
    get "/github"
    assert_equal 200, last_response.status
    img = last_response.headers["Content-Security-Policy"][/img-src ([^;]+)/, 1]
    # + the auth provider's (the test stub: none)
    assert_equal ["'self'", "data:", "https://avatars.githubusercontent.com"], img.split
  end
end
