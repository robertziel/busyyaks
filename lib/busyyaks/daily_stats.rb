# frozen_string_literal: true

require "date"

module Busyyaks
  # The home page's per-day figures. Commits come from the scanned commits — the commits table holds
  # `window_days` of every repo's `git log --all`, so that is the range. Merged PRs come from GitHub (GithubPrs, the
  # `github` collector's search): a day the PR collection does not cover (never read, or before the searched
  # `since`) has prs nil — unknown, never 0.
  module DailyStats
    module_function

    # One row per local day from `days - 1` days ago to today, newest first: [{day, commits, mine, repos, prs}].
    # prs: [{merged_at}] merged PRs; prs_since: the first day GitHub was searched from (Date), nil = never read.
    def days(commits, prs, today:, days:, prs_since:)
      day = ->(t) { Time.at(t).to_date.iso8601 }
      by_day = commits.group_by { |c| day.(c[:committed_at]) }
      prs_by_day = prs.group_by { |p| day.(p[:merged_at]) }
      (0...days).map do |i|
        d = today - i
        cs = by_day[d.iso8601] || []
        { day: d.iso8601, commits: cs.size, mine: cs.count { |c| c[:mine] }, repos: cs.map { |c| c[:project_slug] }.uniq.size,
          prs: prs_since && d >= prs_since ? (prs_by_day[d.iso8601] || []).size : nil, }
      end
    end
  end
end
