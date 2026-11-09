# frozen_string_literal: true

# gh_pr_checks: the notifier (no GitHub token) writes which PRs' checks it wants to know (repo + ref "pr:N" /
# "branch:name", requested_at); the github service (the only token holder) answers them (state, number, finished_at,
# checked_at, error) every GITHUB_CI_INTERVAL_SECONDS. The notifier's CI port reads the answers.
ROM::SQL.migration do
  up do
    create_table :gh_pr_checks do
      primary_key :id
      String :repo, null: false           # owner/name
      String :ref, null: false            # "pr:112" | "branch:feat/x"
      Integer :requested_at, null: false
      Integer :checked_at
      Integer :number                     # the PR's number once known
      String :state                       # success | failure | pending | nochecks | none (no open PR) | closed
      Integer :finished_at                # epoch the last check finished (state success / failure)
      String :error, text: true           # why the last poll failed (token rejected, rate limited, unreachable)
      unique %i[repo ref]
    end
  end

  down do
    drop_table :gh_pr_checks
  end
end
