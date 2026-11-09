# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v3: the agent-session registry (agent_sessions — which session was launched as which type for
# which board, the author name it acts as, when it ended and why). migrate! is idempotent by introspection: here it
# only creates that table; everything else already exists from the migrations above.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 3) # pinned to this step: a fresh DB replays it as it was
  end

  down do
    drop_table(:agent_sessions)
  end
end
