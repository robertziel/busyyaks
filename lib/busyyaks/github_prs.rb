# frozen_string_literal: true

require "time"
require_relative "github_network"

module Busyyaks
  # The operator's merged PRs, from GitHub itself: the search API, `is:pr is:merged author:<login>
  # merged:>=<since>`, every repo the token can see — merge, squash and rebase merges alike. Run by the `github`
  # collector (bin/github, the only GITHUB_TOKEN holder); read by /api/today. A failed read stores nothing and is
  # recorded in gh_pr_runs with the reason; what was stored before stays, shown beside the last good read's time.
  module GithubPrs
    SEARCH_MAX = 1000 # GitHub search never returns more; a window holding more cannot be read whole → error

    module_function

    # One read → the gh_pr_runs row. Never raises for a GitHub failure: the error is the run's result.
    def collect(db:, client:, login:, since:, clock: -> { Time.now.to_i })
      raise GithubNetwork::Error, "GITHUB_LOGIN #{login.inspect} is not a GitHub login" unless login.to_s.match?(GithubNetwork::LOGIN)

      calls = client.calls
      id = db[:gh_pr_runs].insert(login: login, since: since.iso8601, started_at: clock.call)
      begin
        prs = search(client, login, since)
        added = store(db, login, prs, clock.call)
        db[:gh_pr_runs].where(id: id).update(ok: true, error: nil, found: prs.size, added: added, calls: client.calls - calls,
                                             finished_at: clock.call)
      rescue GithubNetwork::Error => e
        db[:gh_pr_runs].where(id: id).update(ok: false, error: e.message, calls: client.calls - calls, finished_at: clock.call)
      end
      db[:gh_pr_runs].where(id: id).first
    end

    def search(client, login, since)
      q = URI.encode_www_form_component("is:pr is:merged author:#{login} merged:>=#{since.iso8601}")
      url = "/search/issues?q=#{q}&per_page=100"
      items = []
      while url
        page = client.get(url)
        b = page.body
        if b["incomplete_results"]
          raise GithubNetwork::Error, "GitHub search incomplete (timed out on GitHub's side): nothing stored"
        end
        if b["total_count"].to_i > SEARCH_MAX
          raise GithubNetwork::Error, "GitHub search found #{b['total_count']} merged PRs since #{since}: " \
                                      "over #{SEARCH_MAX}, cannot read them all"
        end

        items.concat(b["items"])
        url = page.next_url
      end
      items.map do |i|
        merged = i.dig("pull_request", "merged_at") or
          raise GithubNetwork::Error, "GitHub search item #{i['html_url']} has no pull_request.merged_at"
        { repo: i["repository_url"].to_s.delete_prefix("#{GithubNetwork::API}/repos/"), number: i["number"],
          title: i["title"].to_s, url: i["html_url"], merged_at: Time.iso8601(merged).to_i, }
      end
    end

    # → PRs new to the store; a known one gets its current title
    def store(db, login, prs, now)
      t = db[:gh_merged_prs]
      added = 0
      db.transaction do
        prs.uniq { |p| [p[:repo], p[:number]] }.each do |p|
          key = { login: login, repo: p[:repo], number: p[:number] }
          if t.where(key).empty?
            t.insert(p.merge(login: login, first_seen_at: now))
            added += 1
          else
            t.where(key).update(title: p[:title], url: p[:url], merged_at: p[:merged_at])
          end
        end
      end
      added
    end

    # The PRs merged since `from` (newest first) and the collection status: {ok, error, at, last_ok_at, since} —
    # nil when the collector never ran (nothing is known: the page says so, never 0).
    def read(db, login:, from:)
      prs = db[:gh_merged_prs].where(login: login).where { merged_at >= from }.order(Sequel.desc(:merged_at)).all
      last = db[:gh_pr_runs].where(login: login).exclude(finished_at: nil).order(Sequel.desc(:id)).first
      ok = db[:gh_pr_runs].where(login: login, ok: true).order(Sequel.desc(:id)).first
      status = last && { ok: last[:ok], error: last[:error], at: last[:finished_at], last_ok_at: ok && ok[:finished_at],
                         since: ok && ok[:since], }
      [prs, status]
    end
  end
end
