# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# The kanban tables are the vendored engine's now (vendor/agents_kanban, Schema v2). Its migrate! is idempotent by
# introspection: on this database — where every table and column of v1 already exists from the migrations above —
# it only ADDS cards.parent_id and cards.metadata (nullable, no backfill, no rename); on a fresh database it creates
# the eight tables. A later library bump that changes the schema gets a new migration calling migrate! again.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 2) # pinned to this step: a fresh DB replays it as it was
  end

  down do
    alter_table(:cards) do
      drop_column :metadata
      drop_column :parent_id
    end
  end
end
