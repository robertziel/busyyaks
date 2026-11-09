# frozen_string_literal: true

# projects.pr_remote: the repo the checked-out branch's work is pushed to — its PRs, branches and
# CI live there — read by the scanner: branch.<b>.pushRemote → remote.pushDefault → branch.<b>.remote → origin.
# `remote` stays origin (ownership, the project's repo). A row gets it at the next scan; until then no PR links.
ROM::SQL.migration do
  up do
    alter_table(:projects) { add_column :pr_remote, String }
  end

  down do
    alter_table(:projects) { drop_column :pr_remote }
  end
end
