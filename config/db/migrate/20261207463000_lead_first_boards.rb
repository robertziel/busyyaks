# frozen_string_literal: true

require "json"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"
require_relative "../../../lib/busyyaks/agent_settings"
require_relative "../../../lib/busyyaks/clock"

# Lead-first boards: agents_kanban Schema v12 — agent_sessions.lead_id / needs_lead / lead_key_digest and
# the CHECK that a session under a lead has one — and the newest agent settings revision in today's shape
# (Busyyaks::AgentSettings.lead_first: spawns_for / spawn_launcher / launcher_follows → `under` + the lead's `takes`),
# written as a NEW revision (the old one stays as history). A revision already in the new shape is left alone.
AUTHOR = "migration 20261207463000"

ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 12)
    row = self[:agent_settings].reverse(:id).first
    if row
      doc = Busyyaks::AgentSettings.lead_first(JSON.parse(row[:doc]))
      self[:agent_settings].insert(doc: JSON.generate(doc), author: AUTHOR, created_at: Busyyaks::Clock.epoch) if doc
    end
  end

  # Refused while a session under a lead is open (below v12 nothing says which lead it runs under), and while a revision
  # saved after this migration's is in the lead-first shape (`under` / `standalone`: the pre-v12 engine refuses it,
  # and dropping the operator's later edits silently is no rollback) — import a pre-463 revision first
  # (bin/agent-settings import). With no later revision, the one from before the migration comes back as the newest
  # (a NEW row: history stays); a later pre-463 one (imported) is left the newest. Then the columns go.
  down do
    open = self[:agent_sessions].where(ended_at: nil, needs_lead: 1).count
    raise "rollback refused: #{open} open agent session(s) run under a lead — end them first" if open.positive?

    mine = self[:agent_settings].where(author: AUTHOR).reverse(:id).first
    if mine
      later = self[:agent_settings].where(Sequel[:id] > mine[:id]).all
      shaped = later.select { |r| JSON.parse(r[:doc])["agent_types"].any? { |t| t.key?("under") || t.key?("standalone") } }
      if shaped.any?
        raise "rollback refused: agent settings revision(s) #{shaped.map { |r| r[:id] }.join(', ')} saved after " \
              "#{AUTHOR} use `under` / `standalone`, which the pre-lead-first engine refuses — import a pre-463 " \
              "revision (bin/agent-settings import) first"
      end
      before = self[:agent_settings].where(Sequel[:id] < mine[:id]).reverse(:id).first
      self[:agent_settings].insert(doc: before[:doc], author: "#{AUTHOR} rollback", created_at: Busyyaks::Clock.epoch) \
        if before && later.empty?
    end
    alter_table(:agent_sessions) do
      drop_constraint(:agent_sessions_lead_required)
      drop_column :lead_key_digest
      drop_column :needs_lead
      drop_column :lead_id
    end
  end
end
