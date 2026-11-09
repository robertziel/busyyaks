# frozen_string_literal: true

# projects.dirty_paths: the first uncommitted paths of a repo (JSON list of `git status --porcelain` lines, at most
# Scanner::DIRTY_PATHS_MAX), stored by the scanner from the status call it already makes. The daily report's children
# read them over MCP (daily_facts.repos[].dirty_paths) instead of running git on the host.
ROM::SQL.migration do
  up do
    alter_table(:projects) { add_column :dirty_paths, String, text: true }
  end

  down do
    alter_table(:projects) { drop_column :dirty_paths }
  end
end
