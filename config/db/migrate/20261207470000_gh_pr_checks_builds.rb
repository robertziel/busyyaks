# frozen_string_literal: true

# gh_pr_checks.builds (card #470): the build URLs (target_url / details_url) of the commit's REQUIRED CI contexts
# (config/busyyaks.yml ci.required) the github service read for a row, as a JSON list — a handoff's ci_url must be one of
# them (the build of the head it hands over, not an older one or a URL that names no build of it).
ROM::SQL.migration do
  up do
    alter_table(:gh_pr_checks) { add_column :builds, String, text: true }
  end

  down do
    alter_table(:gh_pr_checks) { drop_column :builds }
  end
end
