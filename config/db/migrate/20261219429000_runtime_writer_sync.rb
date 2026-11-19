# frozen_string_literal: true

require "json"
require "busyyaks/clock"
require "busyyaks/runtime_settings"

# writer_sync_seconds joins the runtime settings with the writer service: a database whose newest revision was saved
# before it (no writer_sync_seconds) gets a new revision = that one + writer_sync_seconds at
# config/runtime.template.yml's value (a whole number of seconds, like a save), the other keys as they are, in
# RuntimeSettings::KEYS order (only the keys the revision has: a key a later release adds is that release's
# migration's). A revision that has it already (a fresh database: the template seeded it) or no revision at all →
# nothing written.
# down: a new revision without the key, for the release before the writer (its KEYS refuse an unknown one).
ROM::SQL.migration do
  up do
    row = self[:runtime_settings].reverse(:id).first
    doc = row && JSON.parse(row[:doc])
    if doc && !doc.key?("writer_sync_seconds")
      doc = Busyyaks::RuntimeSettings.template.slice("writer_sync_seconds").merge(doc)
      sync = doc["writer_sync_seconds"]
      raise "config/runtime.template.yml writer_sync_seconds #{sync.inspect}: not a whole number of seconds" unless
        sync.is_a?(Integer) && Busyyaks::RuntimeSettings::BOUNDS.cover?(sync)

      keys = Busyyaks::RuntimeSettings::KEYS.keys
      doc = doc.sort_by { keys.index(_1[0]) || keys.size }.to_h
      self[:runtime_settings].insert(doc: JSON.generate(doc), author: "migration 20261219429000",
                                     created_at: Busyyaks::Clock.epoch)
    end
  end

  down do
    row = self[:runtime_settings].reverse(:id).first
    doc = row && JSON.parse(row[:doc])
    if doc&.key?("writer_sync_seconds")
      self[:runtime_settings].insert(doc: JSON.generate(doc.except("writer_sync_seconds")),
                                     author: "migration 20261219429000", created_at: Busyyaks::Clock.epoch)
    end
  end
end
