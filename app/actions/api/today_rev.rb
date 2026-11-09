# frozen_string_literal: true

require "digest"
require "busyyaks/github_network"
require "busyyaks/github_prs"

module Busyyaks
  module Actions
    module API
      # GET /api/today/rev → {rev, scan} — polled by the home page. `rev` changes when anything /api/today
      # shows changes (repos' state, commits, reports, the GitHub PR read, the local date); the page re-reads
      # /api/today only then. `scan` (the last finished scan) comes with every poll so the "scan Ns ago" label resets
      # after each scan without a full read. Live sessions (launch bar, tree) are not in it: they come with full reads.
      class TodayRev < Busyyaks::APIAction
        def handle(_req, res)
          gh = Busyyaks::GithubNetwork::Data.default.db
          login = ENV.fetch("GITHUB_LOGIN")
          pr_run = gh[:gh_pr_runs].where(login: login).exclude(finished_at: nil).order(Sequel.desc(:id)).get(:id)
          prs = gh[:gh_merged_prs].where(login: login).count
          rev = Digest::SHA256.hexdigest(JSON.dump([Date.today.iso8601, store.today_rev_parts, pr_run, prs]))[0, 16]
          scan = store.last_scan
          json(res, { rev: rev, scan: scan && { finished_at: scan[:finished_at], error: scan[:error] } })
        end
      end
    end
  end
end
