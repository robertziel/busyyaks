# frozen_string_literal: true

require "test_helper"
require_relative "../support/fake_github"
require "busyyaks/github_network"

# the operator's merged PRs from GitHub's search (the `github` collector), stored once, failures recorded
class GithubPrsTest < Minitest::Test
  include DBReset
  GN = Busyyaks::GithubNetwork
  GP = Busyyaks::GithubPrs
  NOW = Time.utc(2026, 11, 6, 12).to_i
  SINCE = Date.new(2026, 10, 30)
  Q = "/search/issues?q=#{URI.encode_www_form_component('is:pr is:merged author:me merged:>=2026-10-30')}&per_page=100".freeze

  def setup
    super
    @gh = FakeGithub.new
    @db = GN::Data.default.db
  end

  def item(repo, n, hours_ago, title: "PR #{n}")
    { "number" => n, "title" => title, "repository_url" => "https://api.github.com/repos/#{repo}",
      "html_url" => "https://github.com/#{repo}/pull/#{n}", "pull_request" => { "merged_at" => Time.at(NOW - (hours_ago * 3600)).utc.iso8601 }, }
  end

  def page(items, total: items.size, incomplete: false)
    { "total_count" => total, "incomplete_results" => incomplete, "items" => items }
  end

  def collect!
    GP.collect(db: @db, client: GN::Client.new(token: "tok", http: @gh), login: "me", since: SINCE, clock: -> { NOW })
  end

  def read = GP.read(@db, login: "me", from: NOW - (7 * 86_400))

  def test_every_page_is_read_and_each_pr_stored_once
    @gh.set(Q, page([item("o/a", 3, 1), item("me/b", 7, 30)], total: 3), link: "#{Q}&page=2")
    @gh.set("#{Q}&page=2", page([item("o/a", 2, 50)], total: 3))
    r = collect!
    assert r[:ok], r[:error]
    assert_equal [3, 3, 2, "2026-10-30"], [r[:found], r[:added], r[:calls], r[:since]]
    prs, status = read
    assert_equal [["o/a", 3], ["me/b", 7], ["o/a", 2]], prs.map { |p| [p[:repo], p[:number]] }, "newest merge first"
    assert_equal "https://github.com/me/b/pull/7", prs[1][:url]
    assert_equal({ ok: true, error: nil, at: NOW, last_ok_at: NOW, since: "2026-10-30" }, status)

    @gh.set(Q, page([item("o/a", 3, 1, title: "renamed")]))
    r = collect!
    assert_equal [1, 0], [r[:found], r[:added]], "a known PR is not added again"
    assert_equal "renamed", read[0][0][:title]
  end

  def test_a_failed_read_stores_nothing_and_says_why
    @gh.set(Q, page([item("o/a", 3, 1)]))
    collect!
    @gh.fail_with = [401, "Bad credentials"]
    r = collect!
    refute r[:ok]
    assert_match(/rejected GITHUB_TOKEN/, r[:error])
    prs, status = read
    assert_equal 1, prs.size, "what was read before stays"
    assert_equal [false, NOW], [status[:ok], status[:last_ok_at]]
  end

  def test_an_incomplete_or_too_large_search_is_an_error_not_a_partial_count
    @gh.set(Q, page([item("o/a", 3, 1)], incomplete: true))
    r = collect!
    refute r[:ok]
    assert_match(/incomplete/, r[:error])
    @gh.set(Q, page([item("o/a", 3, 1)], total: 1001))
    assert_match(/over 1000/, collect![:error])
    assert_empty read[0]
  end

  def test_never_read_is_nil_not_zero
    assert_equal [[], nil], read
  end
end
