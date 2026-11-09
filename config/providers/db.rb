# frozen_string_literal: true

require_relative "../../lib/busyyaks/database"

# hanami-db's connection, from DATABASE_ADAPTER and its keys (lib/busyyaks/database.rb). SQLite — one file shared by
# every service's process: WAL, a stated busy_timeout (SQLITE_BUSY_TIMEOUT_MS) and BEGIN IMMEDIATE transactions, why
# each: lib/busyyaks/sqlite.rb. PostgreSQL: Sequel's postgres adapter (the pg gem), password from the env only.
Hanami.app.configure_provider :db do
  setup = Busyyaks::Database.from_env
  config.gateway :default do |gw|
    gw.database_url = setup.url
    gw.connection_options(**setup.options)
  end

  # the provider's own container: "db.gateway" is not yet imported into the app's at this point
  after :prepare do
    Busyyaks::Database.configure!(container["db.gateway"].connection, setup)
  end
end
