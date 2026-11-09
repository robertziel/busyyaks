# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v10 (card #248): cards.gate_head (the approval PR's head sha the handoff's green CI answer
# carried — a card in an approval gate waits for the operator only while its PR is still at that head) and
# cards.gate_state (what the notifier's last watch pass saw of the card's gate: "ready" or its hold, so a change is
# said once). gh_pr_checks.head: the PR head sha the github service read for a pr: / branch: / head: row (none for a
# merge: row — the working branch's head moves with every merge, it says nothing about the card's PR).
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 10)
    alter_table(:gh_pr_checks) { add_column :head, String }
  end

  down do
    alter_table(:gh_pr_checks) { drop_column :head }
    alter_table(:cards) do
      drop_column :gate_state
      drop_column :gate_head
    end
  end
end
