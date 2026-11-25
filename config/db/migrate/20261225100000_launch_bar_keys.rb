# frozen_string_literal: true

require "json"
require_relative "../../../lib/busyyaks/agent_settings"
require_relative "../../../lib/busyyaks/clock"

# The Launch bar never offers Worker (workers come only from the lead's kanban_spawn: the engine's `launchable: false`)
# and the lead's button says "Launch team lead" (`launch_label`) — Busyyaks::AgentSettings.launch_bar on the newest
# agent settings revision, written as a NEW revision (the old one stays as history); a revision that says either key
# already is left alone. A local variable, never a top-level constant: the migrator loads a file more than once
# ("already initialized constant" on boot).
author = "migration 20261225100000 (Launch bar: worker spawn-only, Launch team lead)"

ROM::SQL.migration do
  up do
    row = self[:agent_settings].reverse(:id).first
    if row
      doc = Busyyaks::AgentSettings.launch_bar(JSON.parse(row[:doc]))
      self[:agent_settings].insert(doc: JSON.generate(doc), author: author, created_at: Busyyaks::Clock.epoch) if doc
    end
  end

  # The revision from before comes back as the newest (a NEW row) — only while nothing was saved after this one.
  down do
    mine = self[:agent_settings].where(author: author).reverse(:id).first
    next unless mine

    later = self[:agent_settings].where(Sequel[:id] > mine[:id]).count
    raise "rollback refused: #{later} agent settings revision(s) saved after #{author}" if later.positive?

    before = self[:agent_settings].where(Sequel[:id] < mine[:id]).reverse(:id).first
    next unless before

    self[:agent_settings].insert(doc: before[:doc], author: "#{author} rollback", created_at: Busyyaks::Clock.epoch)
  end
end
