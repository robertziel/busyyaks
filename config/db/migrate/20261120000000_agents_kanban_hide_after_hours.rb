# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v7: `board_columns.hide_after_hours` — hours without an update after which a card in
# that column folds behind "Load older" on the Board (null = the column type's default: done 24 h, parked 168 h, every
# other type 72 h; 0 = never). Set per column in the Workflow editor ("Fold after (h)").
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 7)
  end

  down do
    alter_table(:board_columns) { drop_column :hide_after_hours }
  end
end
