# frozen_string_literal: true

# gh_pr_checks.detail: what the github service read for a row, in words, with the commit shas — a `merge:<N>` row
# (Local deploy check) names the merge commit and, when that commit has no checks of its own (Jenkins coalesces the
# working branch's builds), the branch head whose checks were read because it contains the merge commit. Shown in the
# approval gate's refusal.
ROM::SQL.migration do
  up do
    alter_table(:gh_pr_checks) { add_column :detail, String, text: true }
  end

  down do
    alter_table(:gh_pr_checks) { drop_column :detail }
  end
end
