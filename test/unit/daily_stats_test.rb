# frozen_string_literal: true

require "test_helper"

# the home page's per-day figures — commits from the scan, merged PRs from GitHub
class DailyStatsTest < Minitest::Test
  DS = Busyyaks::DailyStats

  def at(day, hour) = Time.new(*day.split("-").map(&:to_i), hour).to_i
  def c(slug, t, mine: true) = { project_slug: slug, committed_at: t, mine: mine }

  def test_days_cover_the_window_newest_first_with_empty_days_as_zero
    cs = [c("a", at("2026-11-06", 10)), c("b", at("2026-11-06", 23), mine: false), c("a", at("2026-11-04", 0))]
    prs = [{ merged_at: at("2026-11-06", 9) }, { merged_at: at("2026-11-04", 22) }]
    rows = DS.days(cs, prs, today: Date.new(2026, 11, 6), days: 3, prs_since: Date.new(2026, 10, 30))
    assert_equal [{ day: "2026-11-06", commits: 2, mine: 1, repos: 2, prs: 1 },
                  { day: "2026-11-05", commits: 0, mine: 0, repos: 0, prs: 0 },
                  { day: "2026-11-04", commits: 1, mine: 1, repos: 1, prs: 1 },], rows
  end

  def test_prs_are_unknown_on_days_github_was_not_searched
    rows = DS.days([], [], today: Date.new(2026, 11, 6), days: 3, prs_since: Date.new(2026, 11, 5))
    assert_equal [0, 0, nil], rows.map { |r| r[:prs] }, "before the searched since: unknown, not 0"
    rows = DS.days([], [], today: Date.new(2026, 11, 6), days: 3, prs_since: nil)
    assert_equal [nil, nil, nil], rows.map { |r| r[:prs] }, "never read"
  end
end
