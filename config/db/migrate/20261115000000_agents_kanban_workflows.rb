# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v5: workflows (a project's own named transitions — edited on the board, kept here; no row
# = the board default, config/kanban.yml `workflow`). migrate! is idempotent by introspection: here it only creates that table.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 5) # pinned to this step: a fresh DB replays it as it was
  end

  down do
    drop_table(:workflows)
  end
end
