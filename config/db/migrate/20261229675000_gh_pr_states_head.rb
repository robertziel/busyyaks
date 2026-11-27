# frozen_string_literal: true

# gh_pr_states.head = the PR's head sha the PR-state poller read (GET /pulls/N head.sha, an open / draft PR).
# The rail compares it with the CI row's head (gh_pr_checks.head): a CI answer for another sha is not this head's —
# shown "checks: not read yet", never its old pass or failure. The poller's cache keys digest the field set it keeps
# (PrStates::Poller::KEEP, now with `head`), so no old page is reached any more: the `pr:%` pages are deleted.
ROM::SQL.migration do
  up do
    alter_table(:gh_pr_states) { add_column :head, String }
    self[:gh_pages].where(Sequel.like(:url, "pr:%")).delete
  end

  down do
    alter_table(:gh_pr_states) { drop_column :head }
  end
end
