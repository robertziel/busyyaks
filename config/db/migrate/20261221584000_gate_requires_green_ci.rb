# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v16: whether an approval step waits for green CI is its GATE column's own setting —
# board_columns.requires_green_ci (0/1, null = 0), was config/kanban.yml `approval.requires_green_ci` (now refused at
# boot, naming the move). No data step: after this migration no gate asks CI until the operator ticks "Requires green
# CI" on it in the Workflow editor, or sets `requires_green_ci: true` on it in the repo's .busyyaks/workflow.yml.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 16)
  end

  # before v16 there is no such column: dropped (every gate's choice is lost — the code before it reads the host-wide
  # key instead)
  down do
    alter_table(:board_columns) { drop_column :requires_green_ci }
  end
end
