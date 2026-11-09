# frozen_string_literal: true

# The demo stack's merged PRs (the Today page's PR tile and list): what the `github` collector would have stored from a
# GitHub search, written into the demo database directly — the demo runs no collector and holds no token. Synthetic
# repos (acme/*) and titles only. Run by scripts/readme-images/build inside the demo web container:
#   docker exec -i readme-demo-web-1 bundle exec ruby - < scripts/readme-images/seed-github.rb
require "sequel"

login = ENV.fetch("GITHUB_LOGIN")
db = Sequel.sqlite(ENV.fetch("SQLITE_PATH"))
now = Time.now.to_i
repos = %w[acme/storefront acme/payments-api acme/mobile-app acme/docs-site acme/infra].freeze
titles = [
  "Paginate the product listing", "Fix currency rounding on invoices", "Upgrade to Ruby 3.4",
  "Retry failed webhooks with backoff", "Cache the product query", "Typo-tolerant product search",
  "Order confirmation email redesign", "Health check for the worker queue", "Bump the payment SDK",
  "Log slow requests over 500 ms",
].freeze

db.transaction do
  21.times do |i|
    repo = repos[i % repos.size]
    number = 40 + i
    merged = now - (i * 26_000) - 600
    db[:gh_merged_prs].insert(login: login, repo: repo, number: number, title: titles[i % titles.size],
                              url: "https://github.com/#{repo}/pull/#{number}", merged_at: merged, first_seen_at: merged)
  end
  since = Time.at(now - (6 * 86_400)).strftime("%F")
  db[:gh_pr_runs].insert(login: login, since: since, started_at: now - 30, finished_at: now - 28, ok: true, found: 21,
                         added: 21, calls: 1)
end
puts "seed-github: 21 merged PRs for #{login}"
