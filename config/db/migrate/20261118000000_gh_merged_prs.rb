# frozen_string_literal: true

# Merged PRs: the `github` collector (the only GITHUB_TOKEN holder) searches GitHub for the
# operator's merged PRs (`is:pr is:merged author:GITHUB_LOGIN merged:>=<window start>`) every GITHUB_INTERVAL_SECONDS
# and stores each once (repo + number). Every read is a gh_pr_runs row: ok, or the error — the home page shows it.
ROM::SQL.migration do
  up do
    create_table :gh_merged_prs do
      column :login, String, null: false        # whose PRs (GITHUB_LOGIN)
      column :repo, String, null: false         # owner/name
      column :number, Integer, null: false
      column :title, String, text: true, null: false
      column :url, String, null: false          # html_url
      column :merged_at, Integer, null: false   # GitHub's pull_request.merged_at
      column :first_seen_at, Integer, null: false
      primary_key %i[login repo number]
      index %i[login merged_at]
    end
    create_table :gh_pr_runs do
      primary_key :id
      column :login, String, null: false
      column :since, String, null: false        # the merged:>= date searched (YYYY-MM-DD)
      column :started_at, Integer, null: false
      column :finished_at, Integer
      column :ok, TrueClass
      column :error, String, text: true         # token rejected, rate limited, unreachable, incomplete search
      column :found, Integer                    # PRs the search returned
      column :added, Integer                    # of which new
      column :calls, Integer
      index %i[login id]
    end
  end

  down do
    drop_table :gh_pr_runs
    drop_table :gh_merged_prs
  end
end
