# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v4: ci_watches (what the idle watch already pinged / commented, so a CI completion acts once).
# migrate! is idempotent by introspection: here it only creates that table.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 4) # pinned to this step: a fresh DB replays it as it was
  end

  down do
    drop_table(:ci_watches)
  end
end
