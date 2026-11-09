# frozen_string_literal: true

require "uri"
require_relative "sqlite"
require_relative "postgres"

module Busyyaks
  # Which database the services share, from the env (deployment wiring, .env.example): DATABASE_ADAPTER = sqlite
  # (the shipped example: one file under data/) or postgresql (a server; the compose `postgres` profile or your own).
  # Every key the adapter needs is required; a missing, empty or unknown value fails the boot — no default adapter,
  # path, host or port. Applied to hanami-db's gateway by config/providers/db.rb.
  #
  #   sqlite:     SQLITE_PATH (absolute), SQLITE_BUSY_TIMEOUT_MS (lib/busyyaks/sqlite.rb: WAL, IMMEDIATE)
  #   postgresql: POSTGRES_HOST (a host name, an address, or the directory of a Unix socket), POSTGRES_PORT,
  #               POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD — the password only ever in the env, never in a URL —
  #               and POSTGRES_LOCK_TIMEOUT_MS (lib/busyyaks/postgres.rb: the bound on a writer's wait)
  module Database
    ADAPTERS = %w[sqlite postgresql].freeze
    # url: what hanami-db and the Hanami CLI name the database by (no password); options: Sequel connect options;
    # lock_timeout_ms: how long a writer waits for another's lock (SQLite busy_timeout · PostgreSQL lock_timeout)
    Setup = Data.define(:adapter, :url, :options, :lock_timeout_ms)

    class Invalid < StandardError; end

    module_function

    def from_env(env = ENV)
      if env.key?("DATABASE_URL")
        raise Invalid, "DATABASE_URL is not read: the database is DATABASE_ADAPTER + its keys (.env.example) — remove it"
      end

      adapter = required(env, "DATABASE_ADAPTER")
      case adapter
      when "sqlite" then sqlite(env)
      when "postgresql" then postgresql(env)
      else raise Invalid, "DATABASE_ADAPTER must be one of #{ADAPTERS.join(', ')}, got #{adapter.inspect}"
      end
    end

    def sqlite(env)
      path = required(env, "SQLITE_PATH")
      raise Invalid, "SQLITE_PATH must be an absolute path, got #{path.inspect}" unless path.start_with?("/")

      ms = milliseconds(env, "SQLITE_BUSY_TIMEOUT_MS")
      Setup.new(adapter: "sqlite", url: "sqlite://#{path}", options: Sqlite.connection_options(ms), lock_timeout_ms: ms)
    end

    def postgresql(env)
      host, db, user, password = %w[POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD].map { required(env, _1) }
      port = Integer(required(env, "POSTGRES_PORT"), 10, exception: false)
      raise Invalid, "POSTGRES_PORT must be a port number, got #{env['POSTGRES_PORT'].inspect}" unless port&.between?(1, 65_535)

      Setup.new(adapter: "postgresql", url: "postgres:///#{URI.encode_www_form_component(db)}",
                options: { host: host, port: port, database: db, user: user, password: password },
                lock_timeout_ms: milliseconds(env, "POSTGRES_LOCK_TIMEOUT_MS"))
    end

    # After the gateway connected: the adapter's per-database settings — on both, write transactions run one at a
    # time (SQLite: BEGIN IMMEDIATE; PostgreSQL: an advisory lock, lib/busyyaks/postgres.rb), a wait bounded by
    # setup.lock_timeout_ms.
    def configure!(db, setup)
      case db.database_type
      when :sqlite then Sqlite.configure!(db)
      when :postgres then Postgres.configure!(db, setup.lock_timeout_ms)
      else raise Invalid, "no settings for a #{db.database_type} connection"
      end
    end

    # a positive integer of milliseconds
    def milliseconds(env, key)
      raw = required(env, key)
      ms = Integer(raw, 10, exception: false)
      raise Invalid, "#{key} must be a positive integer of milliseconds, got #{raw.inspect}" unless ms&.positive?

      ms
    end

    def required(env, key)
      value = env.fetch(key) { raise Invalid, "#{key} is required (.env.example)" }
      raise Invalid, "#{key} is empty (.env.example)" if value.to_s.strip.empty?

      value
    end
  end
end
