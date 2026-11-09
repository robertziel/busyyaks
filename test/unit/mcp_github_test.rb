# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "busyyaks/mcp_server"
require "busyyaks/github_network"

# github_network (MCP), check_report's tl:github checks, and the block's validation. Snapshots are written straight
# into the gh_* tables (the collector itself: github_network_test.rb).
class McpGithubTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods

  TOKEN = "t" * 40
  REPORT_TOKEN = "r" * 40
  AV = "https://avatars.githubusercontent.com/u/1?v=4"

  def app = Busyyaks::McpServer.new(token: TOKEN, report_token: REPORT_TOKEN, scan_interval: 60, store: store, config: nil)

  def tool(name, args = {})
    header "Authorization", "Bearer #{TOKEN}"
    post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: args }),
         "CONTENT_TYPE" => "application/json"
    JSON.parse(last_response.body)["result"]
  end

  def db = Hanami.app["db.gateway"].connection

  def setup
    super
    now = Time.now.to_i
    login = ENV.fetch("GITHUB_LOGIN")
    db[:gh_runs].insert(login: login, started_at: now - 100, finished_at: now - 90, ok: true, baseline: true, calls: 9,
                        not_modified: 0, rate_limit: 5000, rate_remaining: 4991, rate_reset: now + 3000, followees: 2,
                        stars_added: 3, follows_added: 0)
    %w[alice bob].each do |u|
      db[:gh_follows].insert(follower: login, followee: u, first_seen_at: now - 90, last_seen_at: now - 90, baseline: true)
      db[:gh_users].insert(login: u, avatar_url: AV, name: u.capitalize)
    end
    db[:gh_repos].insert(full_name: "o/hot", html_url: "https://github.com/o/hot", description: "hot <b>repo</b>",
                         language: "Rust", stargazers_count: 12_345, topics: '["fast"]', owner_avatar: AV, fetched_at: now - 90)
    db[:gh_repos].insert(full_name: "o/cold", html_url: "https://github.com/o/cold", fetched_at: now - 90)
    db[:gh_repos].insert(full_name: "o/ancient", html_url: "https://github.com/o/ancient", fetched_at: now - 90)
    db[:gh_stars].insert(login: "alice", repo: "o/hot", starred_at: now - 7200, first_seen_at: now - 90)
    db[:gh_stars].insert(login: "bob", repo: "o/hot", starred_at: now - 3600, first_seen_at: now - 90)
    db[:gh_stars].insert(login: "bob", repo: "o/cold", starred_at: now - 600, first_seen_at: now - 90)
    db[:gh_stars].insert(login: "bob", repo: "o/ancient", starred_at: now - (3 * 86_400), first_seen_at: now - 90)
    db[:gh_follows].insert(follower: "alice", followee: "carol", first_seen_at: now - 50, last_seen_at: now - 50,
                           baseline: false)
    db[:gh_follows].insert(follower: "alice", followee: "dave", first_seen_at: now - 90, last_seen_at: now - 90, baseline: true)
    db[:gh_users].insert(login: "carol", name: "Carol C", bio: "builds things", followers: 2400, avatar_url: AV)
  end

  def test_github_network_lists_new_stars_and_follows_with_the_block
    res = tool("github_network", hours: 24)
    assert_equal false, res["isError"], res.dig("content", 0, "text")
    out = JSON.parse(res["content"][0]["text"])
    assert_equal [["o/hot", %w[alice bob]], ["o/cold", ["bob"]]], out["repos"].map { |r| [r["repo"], r["starred_by"]] }
    assert_equal [["carol", ["alice"]]], out["people"].map { |p| [p["login"], p["followed_by"]] },
                 "baseline follows (dave) are never new"
    assert_equal true, out.dig("status", "ok")
    assert_equal 4991, out.dig("status", "rate_remaining")
    assert_match(/\A\d{4}-\d\d-\d\dT/, out.dig("status", "last_ok_at"))
    assert out["block_markdown"].start_with?("```tl:github\n")

    check = JSON.parse(tool("check_report", body_markdown: out["block_markdown"])["content"][0]["text"])
    assert_equal [], check["broken"]
    assert_equal [], check["github_unverified"]

    forged = out["block_markdown"].sub("login: carol", "login: mallory")
    check = JSON.parse(tool("check_report", body_markdown: forged)["content"][0]["text"])
    assert_equal ["tl:github (block 1): @mallory — no stored new follow by @alice"], check["github_unverified"]
  end

  def test_github_network_has_the_feed_part_and_check_report_verifies_it
    now = Time.now.to_i
    login = ENV.fetch("GITHUB_LOGIN")
    db[:gh_runs].where(login: login).update(feed_ok: true, feed_added: 2, feed_calls: 3, feed_not_modified: 0, feed_gap: false)
    db[:gh_events].insert(login: login, id: "901", type: "ReleaseEvent", action: "published", actor: "alice", actor_avatar: AV,
                          repo: "alice/lib", public: true, created_at: now - 600, first_seen_at: now,
                          digest: JSON.generate("tag" => "v1.0.0", "name" => "One"))
    db[:gh_events].insert(login: login, id: "902", type: "PushEvent", actor: "bob", actor_avatar: AV, repo: "bob/app",
                          public: true, created_at: now - 700, first_seen_at: now,
                          digest: JSON.generate("ref" => "refs/heads/main"))
    out = JSON.parse(tool("github_network", hours: 24)["content"][0]["text"])
    f = out["feed"]
    assert_equal true, f.dig("status", "ok")
    assert_equal({ "ReleaseEvent" => 1, "PushEvent" => 1 }, f["counts"])
    assert_equal [["release", "alice", "alice/lib", "v1.0.0"]],
                 f["items"].map { |i| i.values_at("kind", "actor", "repo", "tag") }
    assert_match(/\A\d{4}-/, f["items"][0]["at"])
    assert_equal [["bob/app", 1, ["bob"]]], f["pushes"].map { |x| x.values_at("repo", "pushes", "actors") }
    assert_equal %w[alice/lib bob/app].sort, f["by_repo"].map { |r| r["repo"] }.sort
    md = out["block_markdown"]
    assert_includes md, "kind: release"
    check = JSON.parse(tool("check_report", body_markdown: md)["content"][0]["text"])
    assert_equal [[], []], [check["broken"], check["github_unverified"]]
    check = JSON.parse(tool("check_report", body_markdown: md.sub("tag: v1.0.0", "tag: v6.6.6"))["content"][0]["text"])
    assert_equal ["tl:github (block 1): feed release alice/lib (event \"901\") — tag not as stored"], check["github_unverified"]
  end

  def test_week_window_includes_older_stars
    out = JSON.parse(tool("github_network", hours: 168)["content"][0]["text"])
    assert_includes out["repos"].map { |r| r["repo"] }, "o/ancient"
  end

  def test_hours_out_of_range_is_a_tool_error
    res = tool("github_network", hours: 0)
    assert_equal true, res["isError"]
    assert_match(/hours must be 1\.\.720/, res["content"][0]["text"])
  end

  def test_collector_error_is_in_status_and_block
    db[:gh_runs].insert(login: ENV.fetch("GITHUB_LOGIN"), started_at: Time.now.to_i - 10, finished_at: Time.now.to_i - 5,
                        ok: false, baseline: false,
                        error: "GitHub rate limited (0/5000 left, resets 13:00) at /users/bob/starred")
    out = JSON.parse(tool("github_network", hours: 24)["content"][0]["text"])
    assert_equal false, out.dig("status", "ok")
    assert_match(/rate limited/, out.dig("status", "error"))
    html = Busyyaks::Markdown.report(out["block_markdown"], store)
    assert_includes html, %(class="ghn-error")
    assert_includes html, "rate limited"
    assert_includes html, "o/hot", "stored data stays, labelled with the last good collection"
  end

  def test_listed_in_tools
    header "Authorization", "Bearer #{TOKEN}"
    post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list"), "CONTENT_TYPE" => "application/json"
    assert_includes JSON.parse(last_response.body).dig("result", "tools").map { |t| t["name"] }, "github_network"
  end
end

class GithubBlockTest < Minitest::Test
  include DBReset
  AV = "https://avatars.githubusercontent.com/u/1?v=4"

  def html(body) = Busyyaks::Markdown.report("```tl:github\n#{body}```\n", store)

  def test_empty_window_says_nothing_new
    out = html("window: 1d\ncollected: \"2026-11-02T10:00:00Z\"\n")
    assert_includes out, %(<p class="ghn-empty">nothing new in 1d</p>)
    refute_includes out, "tl-error"
  end

  def test_error_only_shows_the_error
    out = html("window: 1d\nerror: \"GitHub rejected GITHUB_TOKEN (401): Bad credentials\"\n")
    assert_includes out, "ghn-error"
    assert_includes out, "Bad credentials"
    refute_includes out, "nothing new"
  end

  def test_rejects_foreign_image_hosts_and_unknown_logins
    assert_includes html("window: 1d\nnetwork: { a: \"https://evil.example/x.png\" }\n" \
                         "repos: [{ repo: o/r, starred_by: [a] }]\n"),
                    "must be an https://avatars.githubusercontent.com/ URL"
    assert_includes html("window: 1d\nnetwork: { a: \"#{AV}\" }\nrepos: [{ repo: o/r, starred_by: [b] }]\n"),
                    "@b is not in network"
    assert_includes html("window: 1d\nrepos: [{ repo: \"javascript:alert(1)\", starred_by: [a] }]\n"), "is not owner/name"
    assert_includes html("window: 1d\nrepos: [{ repo: o/r, starred_by: [] }]\n"), "starred_by must be a non-empty list"
  end

  def test_values_are_escaped_and_links_go_to_github_only
    out = html("window: 1d\nnetwork: { a: \"#{AV}\" }\n" \
               "repos: [{ repo: o/r, description: \"<script>x</script>\", starred_by: [a] }]\n" \
               "people: [{ login: p, bio: \"<img src=x>\", followed_by: [a] }]\n")
    refute_includes out, "<script>x"
    refute_includes out, "<img src=x>"
    hrefs = out.scan(/href="([^"]+)"/).flatten
    assert hrefs.all? { |h| h.start_with?("https://github.com/") }, hrefs.inspect
    srcs = out.scan(/src="([^"]+)"/).flatten
    assert srcs.all? { |s| s.start_with?("https://avatars.githubusercontent.com/") }, srcs.inspect
  end

  def test_star_counts_and_language_dot
    out = html("window: 1d\nnetwork: { a: \"#{AV}\" }\n" \
               "repos: [{ repo: o/r, language: Python, stars: 12345, starred_by: [a] }]\n")
    assert_includes out, "12.3k"
    assert_includes out, "--lang:#3572A5"
  end
end
