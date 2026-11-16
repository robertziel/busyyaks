# frozen_string_literal: true

# A PR's base, draft, mergeability and auto-merge, on the card's rail and at the approval gates.
# projects.local_base / public_base: the branch each side's PRs must be based on — guard.localBranch and
#   guard.publicBase's branch (Scanner#bases); nil when the enrolment does not say (local_error says why).
# gh_pr_states (the rail): base (the PR's base.ref), merge_state (GitHub's mergeable_state as it names it, with
#   conflicts | computing | unknown: <value> — PrStates.merge_state; mergeable null = still computing, never guessed;
#   nil once the PR is merged or closed), auto_merge (auto-merge on).
# gh_pr_checks (the gates): base, draft, merge_state, auto_merge of an open pr:<N> row — the approval refuses a draft,
#   a PR on another base, one that conflicts, one with GitHub's auto-merge on, and one still being computed (behind
#   is only warned about on the rail). The CI poller's cache keys digest the field set it keeps
#   (CiChecks::Poller::KEEP), so the new KEEP already reaches no old page: the `ci:%` delete only clears the pages no
#   key reaches any more.
ROM::SQL.migration do
  up do
    alter_table(:projects) do
      add_column :local_base, String
      add_column :public_base, String
    end
    alter_table(:gh_pr_states) do
      add_column :base, String
      add_column :merge_state, String
      add_column :auto_merge, TrueClass
    end
    alter_table(:gh_pr_checks) do
      add_column :base, String
      add_column :draft, TrueClass
      add_column :merge_state, String
      add_column :auto_merge, TrueClass
    end
    self[:gh_pages].where(Sequel.like(:url, "ci:%")).delete
  end

  down do
    alter_table(:gh_pr_checks) { %i[base draft merge_state auto_merge].each { |c| drop_column c } }
    alter_table(:gh_pr_states) { %i[base merge_state auto_merge].each { |c| drop_column c } }
    alter_table(:projects) { %i[local_base public_base].each { |c| drop_column c } }
  end
end
