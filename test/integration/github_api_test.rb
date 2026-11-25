# frozen_string_literal: true

require "test_helper"
require "rack/test"
require_relative "../support/green_ci"

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
    now = Busyyaks::Clock.epoch
    login = GitHostFixture::LOGIN
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

  # card #470: an enrolled project's repo config ci.required does not list is said on /github (its cards' CI gate is
  # refused) — the github service keeps polling every other project's PRs
  def test_repos_missing_from_ci_required_are_listed
    sign_in
    assert_equal [], get_json("/api/github?hours=24")["ci_unconfigured"]
    db[:projects].insert(slug: "x", path: "/projects/x", remote: "git@github.com:p/x.git", own: true, commits_window: 0,
                         mine_window: 0, dirty: 0, scanned_at: 0, local_mode: "own",
                         local_repo: "git@github.com:o/r.git", public_repo: "https://github.com/p/x.git")
    assert_equal ["p/x"], get_json("/api/github?hours=24")["ci_unconfigured"], "o/r is in the fixture's ci.required"
  end

  # card #511: a card the operator can Approve whose CI reads the github service no longer polls is said on /github
  # (its Approve would be refused "not read yet"), with the card's page and each read
  def test_a_gated_card_whose_ci_reads_left_the_poll_window_is_listed
    sign_in
    out = get_json("/api/github?hours=24")
    assert_equal [], out["gate_stale"]
    assert_equal 600, out["ci_window"], "10 × github_ci_interval_seconds"
    db[:projects].insert(slug: "x", path: "/projects/x", remote: "git@github.com:o/r.git", own: true, commits_window: 0,
                         mine_window: 0, dirty: 0, scanned_at: 0, local_mode: "own", local_repo: "git@github.com:o/r.git",
                         public_repo: "git@github.com:p/x.git")
    kb = Busyyaks::Kanban.default
    kb.board_save("x", GreenCi.fixture("local_v4"), by: "operator") # its gates ask CI
    id = kb.create(slug: "x", title: "dragged here", by: "op", column: "awaiting_merge")
    kb.assign_pr(id, url: "https://github.com/o/r/pull/9", role: "local", by: "op")
    assert_equal [{ "card" => id, "project" => "x", "column" => "awaiting_merge", "path" => "/projects/x?tab=board&card=#{id}",
                    "reads" => [{ "repo" => "o/r", "ref" => "pr:9", "age" => nil }], }],
                 get_json("/api/github?hours=24")["gate_stale"]
    assert_equal 0, db[:gh_pr_checks].count, "the guard asks nothing"
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
    # + the auth provider's (the test stub: none) + the origin of kanban.yml avatar_url (a person's picture)
    assert_equal ["'self'", "data:", "https://avatars.githubusercontent.com", "https://gravatar.com"], img.split
  end
end
