# frozen_string_literal: true

require "json"
require "busyyaks/clock"
require "busyyaks/runtime_settings"

# runtime_settings: the services' timing — once .env SCAN_INTERVAL_SECONDS, GITHUB_INTERVAL_SECONDS,
# GITHUB_CI_INTERVAL_SECONDS, NOTIFIER_INTERVAL_SECONDS, NOTIFIER_WATCH_SECONDS,
# WATCHDOG_GRACE_SECONDS — as revisions; the newest row is the current one (Busyyaks::RuntimeSettings), edited on
# Settings → Runtime. The first revision is config/runtime.template.yml (the values .env.example shipped), validated
# like a save; a deployment that ran other values imports its .env lines (bin/runtime-settings import-env < .env).
# down: the table goes, and with it every revision — put the six keys back into .env and compose first.
ROM::SQL.migration do
  up do
    create_table(:runtime_settings) do
      primary_key :id
      String :doc, text: true, null: false # JSON {scan_interval_seconds, …}
      String :author, null: false
      Integer :created_at, null: false
    end
    doc = Busyyaks::RuntimeSettings.template
    Busyyaks::RuntimeSettings.values!(doc)
    self[:runtime_settings].insert(doc: JSON.generate(doc), author: "migration 20261217523000",
                                   created_at: Busyyaks::Clock.epoch)
  end

  down do
    drop_table(:runtime_settings)
  end
end
