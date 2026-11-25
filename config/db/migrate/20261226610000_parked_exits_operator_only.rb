# frozen_string_literal: true

require "json"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v19: only the operator moves a card out of a parked column (Backlog). With Prioritise open to
# agents (by: any), a lead could move Backlog cards to To do and spawn a worker on each. The
# engine now refuses an agent's move out of a parked column and any workflow that gives agents a way out (on save AND
# on load); its data step (parked_exits!) rewrites every stored board so it loads: each transition by agent|any leaving
# a parked column becomes the operator's there (Prioritise by: operator; a "*" catch-all is split — agents keep it from
# every other column). The writer then writes each changed board back to its repo's .busyyaks/workflow.yml (the stored
# board moved while the file holds the bytes last applied).
#
# Pinned to its step like every host migration: migrate!(to: 19). It replays v17 (lead_assignees!) and v18
# (board_transitions.comment, 20261225613000), both idempotent; v17 needs the lead types, read as
# 20261225612000 reads them.
#
# down: nothing to undo — a v18 engine reads the rewritten boards as they are (an operator-only Prioritise is a valid
# v18 workflow); giving agents a way out of Backlog again is not a rollback this repo offers.
ROM::SQL.migration do
  up do
    row = self[:agent_settings].reverse(:id).first
    leads = row && JSON.parse(row[:doc]).fetch("agent_types").filter_map { |t| t["under"] }.uniq
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 19, lead_types: leads)
  end

  down do
    # no DDL of this step; the rewritten transitions stay the operator's (see above)
  end
end
