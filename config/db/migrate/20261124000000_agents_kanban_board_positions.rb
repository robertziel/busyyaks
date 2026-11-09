# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v9: `board_columns.x` / `y` dropped — the Workflow editor lays the graph out itself on every open
# (dagre, folded into rows that fit the screen; card #234), so no position is stored. A board column is
# {key, label, type, hide_after_hours}; an `x` / `y` in a save is refused as an unknown key.
#
# down: x / y back, NOT NULL as v6 created them, every row at the serpentine the v6 – v8 editor seeded
# (Schema.restore_xy!) — what the v8 code reads.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 9)
  end

  down do
    AgentsKanban::Schema.restore_xy!(self, prefix: "")
  end
end
