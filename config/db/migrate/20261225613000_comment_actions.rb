# frozen_string_literal: true

require "json"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v18: a workflow transition may be a COMMENT ACTION — board_transitions.comment (0/1,
# null = 0): the card's comment box offers "Comment & <name> → <column>", posting the comment and moving the card along
# the transition in one go. No data step of its own: no transition is one until the operator ticks "Comment action" on
# it in the Workflow editor, or sets `comment: true` on it in the repo's .busyyaks/workflow.yml. Runs after v17
# (20261225612000): `to: 18` re-runs v17's idempotent lead-assignee step, which needs the lead types — read as v17's
# migration reads them (the newest agent settings revision: every type some other type runs `under`).
ROM::SQL.migration do
  up do
    row = self[:agent_settings].reverse(:id).first
    leads = row && JSON.parse(row[:doc]).fetch("agent_types").filter_map { |t| t["under"] }.uniq
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 18, lead_types: leads)
  end

  # before v18 there is no such column: dropped (every transition's choice is lost — the code before it has no comment
  # actions)
  down do
    alter_table(:board_transitions) { drop_column :comment }
  end
end
