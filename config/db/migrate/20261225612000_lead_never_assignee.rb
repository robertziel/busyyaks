# frozen_string_literal: true

require "json"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v17 (card 612): a lead is never a card's assignee — only workers are. + cards.worker_wait_at /
# worker_wait_told_at (the worker watch: since when a card waits for a worker, and when the lead was told), and a data
# step: every open card whose assignee is a lead's agent name loses it (the owner session, the lead, is kept; an
# activity line by "migration" says why). The lead types are the agent settings' (the newest revision: every type some
# other type runs `under`) — read here, never guessed; no revision while a card is assigned to a registered agent →
# the engine refuses, naming the step.
ROM::SQL.migration do
  up do
    row = self[:agent_settings].reverse(:id).first
    leads = row && JSON.parse(row[:doc]).fetch("agent_types").filter_map { |t| t["under"] }.uniq
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 17, lead_types: leads)
  end

  # Refused while any card carries the step's line (rolling back would make a lead a card's assignee again: restore the
  # backup taken before the deploy instead); else the two columns are dropped.
  down do
    AgentsKanban::Schema.lead_assignees_down!(self, prefix: "")
    alter_table(:cards) do
      drop_column :worker_wait_told_at
      drop_column :worker_wait_at
    end
  end
end
