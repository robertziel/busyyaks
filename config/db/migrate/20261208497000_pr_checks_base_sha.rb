# frozen_string_literal: true

# An approval on a PR that conflicts with its base is accepted and marked needs rebase (the engine's
# rebase: answer, CiChecks::Port#mergeable). gh_pr_checks.base_sha = the base commit GitHub compared an open pr:<N>
# row's PR with (base.sha) — what the owner rebases onto, named on the card. The CI poller's cache already keeps
# base.sha (KEEP has "sha"), so no cached page is cleared: the next poll fills it.
ROM::SQL.migration do
  up do
    alter_table(:gh_pr_checks) { add_column :base_sha, String }
  end

  down do
    alter_table(:gh_pr_checks) { drop_column :base_sha }
  end
end
