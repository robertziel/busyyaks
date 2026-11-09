# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "busyyaks/search"
require "busyyaks/kanban"

class SearchTest < Minitest::Test
  include DBReset

  def db = Hanami.app["db.gateway"].connection
  def search(q, **kw)
    Busyyaks::Search.new(db, kanban_columns: Busyyaks::Kanban.columns, tables: Busyyaks::Kanban.default.tables).run(q, **kw)
  end
  def group(res, key) = res[:groups].find { |g| g[:key] == key }

  def setup
    super
    %i[cards card_activity].each { |t| db[t].delete }
    store.upsert_project(slug: "acme/sunpogoda", path: "/projects/acme/sunpogoda", remote: "git@github.com:o/d.git",
                         branch: "production", own: true, last_commit_at: 2, commits_window: 1, mine_window: 1, dirty: 9,
                         unpushed: 1, scanned_at: 1)
    store.upsert_project(slug: "pogo-tools", path: "/projects/pogo-tools", remote: nil, branch: "main", own: true,
                         last_commit_at: 5, commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    commit = { sha: "abcdef1234567", author: "R", email: "r@x", committed_at: 10, subject: "fix pogoda radar", mine: true }
    store.replace_commits("pogo-tools", [commit], 0)
    store.add_report(date: "2026-11-01", title: "Daily", body_md: "the pogoda site shipped a 100% fix_ok", author: "claude")
    store.add_note(body: "check POGODA secrets", author: "me", project_slug: "pogo-tools")
    k = Busyyaks::Kanban.default
    k.create(slug: "pogo-tools", title: "Unrelated title", by: "me").then do |c|
      k.comment(c.is_a?(Hash) ? c[:id] : c, body: "pogoda comment hit", author: "me")
    end
    k.create(slug: "pogo-tools", title: "Pogoda card", by: "me")
  end

  def test_every_source_is_searched
    res = search("pogoda")
    assert_equal %w[projects cards commits reports notes agents].sort - ["agents"], res[:groups].map { |g| g[:key] }.sort
    assert_equal "acme/sunpogoda", group(res, "projects")[:items].first[:title]
    assert_equal ["Pogoda card", "Unrelated title"], group(res, "cards")[:items].map { |i| i[:title] }
    assert_includes group(res, "cards")[:items].last[:snippet], "pogoda comment hit"
    assert_match %r{\?tab=board&card=\d+\z}, group(res, "cards")[:items].first[:href]
    assert_equal "/commit/abcdef1234567", group(res, "commits")[:items].first[:href]
  end

  def test_prefix_ranks_before_substring
    assert_equal %w[pogo-tools acme/sunpogoda], group(search("pogo"), "projects")[:items].map { |i| i[:title] }
  end

  def test_sha_prefix_and_like_wildcards_are_literal
    assert_equal "fix pogoda radar", group(search("abcdef1"), "commits")[:items].first[:title]
    assert_nil group(search("%"), "reports").to_h[:items]&.find { |i| i[:title] != "Daily" }
    assert_equal ["Daily"], group(search("100%"), "reports")[:items].map { |i| i[:title] }
    assert_nil group(search("fix_k"), "reports"), "_ must not be a wildcard"
  end

  def test_agents_error_is_reported_not_hidden
    res = search("pogoda", agents_error: "launcher not reachable")
    assert_equal "launcher not reachable", group(res, "agents")[:error]
  end

  def test_blank_query_is_empty
    assert_equal [], search("  ")[:groups]
  end
end
