# frozen_string_literal: true

require "json"
require_relative "../../../lib/busyyaks/agent_settings"
require_relative "../../../lib/busyyaks/clock"

# Every tmux session busyyaks starts is named `by_…` (2026-11-24: busyyaks touches only the sessions it started, and
# a session the operator starts by hand never carries the prefix). The newest agent settings revision gets the prefix
# on every agent type's session_name, written as a NEW revision (the old one stays as history); one that has it
# already is left alone. Without this, every launch of an existing install would be refused until a hand import.
# a local variable, never a top-level constant: the migrator loads a file more than once ("already initialized
# constant" on boot)
prefix_author = "migration 20261224600000 (by_ session names)"

ROM::SQL.migration do
  up do
    row = self[:agent_settings].reverse(:id).first
    if row
      doc = Busyyaks::AgentSettings.prefixed(JSON.parse(row[:doc]))
      self[:agent_settings].insert(doc: JSON.generate(doc), author: prefix_author, created_at: Busyyaks::Clock.epoch) if doc
    end
  end

  # The revision from before the migration comes back as the newest (a NEW row: history stays) — only while nothing was
  # saved after the migration's revision (dropping the operator's later edits silently is no rollback).
  down do
    mine = self[:agent_settings].where(author: prefix_author).reverse(:id).first
    next unless mine

    later = self[:agent_settings].where(Sequel[:id] > mine[:id]).count
    raise "rollback refused: #{later} agent settings revision(s) saved after #{prefix_author}" if later.positive?

    before = self[:agent_settings].where(Sequel[:id] < mine[:id]).reverse(:id).first
    next unless before

    self[:agent_settings].insert(doc: before[:doc], author: "#{prefix_author} rollback", created_at: Busyyaks::Clock.epoch)
  end
end
