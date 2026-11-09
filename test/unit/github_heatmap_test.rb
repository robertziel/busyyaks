# frozen_string_literal: true

require "test_helper"
require "busyyaks/github"
require "busyyaks/heatmap"
require "busyyaks/markdown"

class GithubHeatmapTest < Minitest::Test
  include DBReset

  def test_github_urls_only_for_github
    assert_equal "https://github.com/o/r/commit/abc", Busyyaks::Github.commit_url("git@github.com:o/r.git", "abc")
    assert_equal "https://github.com/o/r", Busyyaks::Github.repo_url("https://github.com/o/r")
    assert_nil Busyyaks::Github.repo_url("https://gitlab.com/o/r.git")
    assert_nil Busyyaks::Github.repo_url(nil)
  end

  def test_heatmap_has_a_year_of_cells_and_levels
    today = Date.new(2026, 11, 1)
    svg = Busyyaks::Heatmap.svg({ "2026-11-01" => 8, "2026-10-31" => 1 }, today: today)
    assert_operator svg.scan("<rect").size, :>=, 365
    assert_includes svg, 'class="l4"><title>8 commits on Nov 1, 2026'
    assert_includes svg, 'class="l1"><title>1 commit on Oct 31, 2026'
    assert_equal 9, Busyyaks::Heatmap.total({ "2026-11-01" => 8, "2026-10-31" => 1, "2024-01-01" => 50 }, today: today)
  end

  def test_report_links_only_known_shas
    store.replace_commits("r", [{ sha: "abcdef1234567", author: "a", email: "a@x", committed_at: Time.now.to_i, subject: "s",
                                  mine: true, }], 0)
    html = Busyyaks::Markdown.report("fix `abcdef12` and `deadbee`", store)
    assert_includes html, '<a class="gh-ref gh-commit" href="/commit/abcdef1234567"'
    assert_includes html, '<code class="gh-sha">abcdef1</code><span class="gh-subj">s</span>'
    assert_includes html, "<code>deadbee</code>"
    refute_includes html, 'href="/commit/deadbee"'
  end

  def test_daily_counts_round_trip
    store.replace_daily("r", { "2026-11-01" => [3, 2] })
    store.replace_daily("s", { "2026-11-01" => [1, 0] })
    assert_equal({ "2026-11-01" => 4 }, store.daily)
    assert_equal({ "2026-11-01" => 2 }, store.daily(mine_only: true))
  end
end

class HeatmapMonthsTest < Minitest::Test
  def test_each_month_labelled_once
    svg = Busyyaks::Heatmap.svg({}, today: Date.new(2026, 11, 1))
    labels = svg.scan(%r{<text x="\d+" y="10">(\w+)</text>}).flatten
    assert_equal labels.uniq, labels
    assert_includes labels, "Dec"
  end
end
