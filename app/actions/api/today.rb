# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      # GET /api/today — the home page's data: stat tiles, year graph counts, today's reports (rendered), today's
      # commits, 7-day activity, per-day figures over the scan window + the operator's merged PRs from GitHub
      # (DailyStats, GithubPrs), the repos active in 7 days as a tree, launch state.
      class Today < Busyyaks::APIAction
        def handle(_req, res)
          now = Time.now
          today = now.to_date.iso8601
          midnight = Time.new(now.year, now.month, now.day).to_i
          week = now.to_i - (7 * 86_400)
          projects = store.projects
          remotes = projects.to_h { |p| [p[:slug], p[:remote]] }
          state = launch_state
          reports = store.reports(date: today)
          latest = reports.empty? ? store.reports(limit: 1).first : nil
          today_activity = store.activity_since(midnight)
          year = store.daily(mine_only: true)
          scan = store.last_scan
          window_days = Config.load.window_days
          first = now.to_date - (window_days - 1) # the scanner keeps window_days × 24 h, so this whole local day is in it
          from = Time.new(first.year, first.month, first.day).to_i
          window = store.commits(since: from, limit: 1_000_000)
          prs, pr_status = Busyyaks::GithubPrs.read(Busyyaks::GithubNetwork::Data.default.db,
                                                    login: ENV.fetch("GITHUB_LOGIN"), from: from)
          prs_since = pr_status && pr_status[:since] && Date.iso8601(pr_status[:since])
          prs_today_known = prs_since && prs_since <= now.to_date
          slugs = projects.each_with_object({}) do |p, h|
            [p[:pr_remote], p[:remote]].each do |r|
              (u = Busyyaks::Github.repo_url(r)) && (h[u.delete_prefix("https://github.com/")] ||= p[:slug])
            end
          end
          active_projects = projects.select { |p| p[:last_commit_at].to_i >= week }
          json(res, {
                 today: today,
                 stats: { repos: projects.size, active7: projects.count { |p| p[:last_commit_at].to_i >= week },
                          commits_today: today_activity.sum { |r| r[:commits] },
                          dirty: projects.count { |p| p[:dirty].positive? },
                          unpushed: projects.count { |p| p[:unpushed].to_i.positive? },
                          prs_today: prs_today_known ? prs.count { |p| p[:merged_at] >= midnight } : nil, },
                 days: Busyyaks::DailyStats.days(window, prs, today: now.to_date, days: window_days, prs_since: prs_since),
                 merged_prs: prs.first(60).map do |p|
                   p.slice(:repo, :number, :title, :url, :merged_at).merge(project_slug: slugs[p[:repo]])
                 end,
                 merged_prs_total: prs.size,
                 pr_status: pr_status,
                 scan: scan && { started_at: scan[:started_at], finished_at: scan[:finished_at],
                                 repos: scan[:repos], error: scan[:error], },
                 year: year, year_total: Busyyaks::Heatmap.total(year), year_all: Busyyaks::Heatmap.total(store.daily),
                 reports: reports.map { |r| Busyyaks::API.report(r, store) },
                 latest: latest && Busyyaks::API.report(latest, store),
                 today_commits: store.commits(since: midnight, limit: 60)
                                     .map { |c| Busyyaks::API.commit(c, remotes[c[:project_slug]]) },
                 week_activity: store.activity_since(week).first(14),
                 active_tree: Busyyaks::API.tree(Busyyaks::Tree.build(active_projects), state[:sessions]),
                 projects_total: projects.size,
                 **launch_json(state),
               })
        end
      end
    end
  end
end
