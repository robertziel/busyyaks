# frozen_string_literal: true

# gh_pr_states: a PR closed without merging keeps WHEN it closed (closed_at, the PR's own closed_at — the
# engine's PR watch tells each close once, keyed by it) and WHY (reason, read once per close from the PR's issue events:
# "base deleted" | "head deleted" | "by <login>"). Both nil for any other state.
ROM::SQL.migration do
  up do
    alter_table(:gh_pr_states) do
      add_column :closed_at, Integer
      add_column :reason, String
    end
  end

  down do
    alter_table(:gh_pr_states) do
      drop_column :reason
      drop_column :closed_at
    end
  end
end
