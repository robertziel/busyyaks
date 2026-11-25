# frozen_string_literal: true

require "json"
require_relative "../../../lib/busyyaks/agent_settings"
require_relative "../../../lib/busyyaks/clock"

# The lead type's label is its NAME — "Team lead" — never "Launch", the button text it used to carry (2026-11-25,
# the operator: "what's sub team? where is lead?"). The newest agent settings revision gets it on every lead type still
# labelled "Launch", written as a NEW revision (the old one stays as history); a revision with none is left alone.
# a local variable, never a top-level constant: the migrator loads a file more than once ("already initialized
# constant" on boot)
lead_label_author = "migration 20261225000000 (the lead's label: Team lead)"

ROM::SQL.migration do
  up do
    row = self[:agent_settings].reverse(:id).first
    if row
      doc = Busyyaks::AgentSettings.lead_named(JSON.parse(row[:doc]))
      if doc
        self[:agent_settings].insert(doc: JSON.generate(doc), author: lead_label_author,
                                     created_at: Busyyaks::Clock.epoch)
      end
    end
  end

  # The revision from before comes back as the newest (a NEW row) — only while nothing was saved after this one.
  down do
    mine = self[:agent_settings].where(author: lead_label_author).reverse(:id).first
    next unless mine

    later = self[:agent_settings].where(Sequel[:id] > mine[:id]).count
    raise "rollback refused: #{later} agent settings revision(s) saved after #{lead_label_author}" if later.positive?

    before = self[:agent_settings].where(Sequel[:id] < mine[:id]).reverse(:id).first
    next unless before

    self[:agent_settings].insert(doc: before[:doc], author: "#{lead_label_author} rollback",
                                 created_at: Busyyaks::Clock.epoch)
  end
end
