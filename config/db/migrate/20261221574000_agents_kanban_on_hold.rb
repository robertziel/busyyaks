# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# On hold. agents_kanban Schema v15 = cards.on_hold_at / on_hold_by (Store#hold: the operator parks a card
# where it sits — out of the board's normal view, every count and watch, and every agent's sight). The rollback drops
# both: a held card is a live card again.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 15)
  end

  down do
    alter_table(:cards) do
      drop_column :on_hold_by
      drop_column :on_hold_at
    end
  end
end
