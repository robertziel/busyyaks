# frozen_string_literal: true

module Busyyaks
  # How every process opens the one SQLite file the services share (web, mcp, scanner, github, notifier — five
  # processes, one data/busyyaks.sqlite3). Applied to hanami-db's connection by config/providers/db.rb.
  #
  # - WAL journal: readers never block the writer and the writer never blocks readers; one writer at a time.
  # - busy_timeout (SQLITE_BUSY_TIMEOUT_MS, required): how long a writer waits for the write lock another process
  #   holds before SQLite gives up with "database is locked". Stated in the env, never Sequel's built-in 5000.
  # - every transaction is BEGIN IMMEDIATE: it takes the write lock when it starts. A deferred transaction that
  #   reads first and writes later (Store#create: count the column, then insert) has to UPGRADE its read lock; when
  #   another process wrote in between, SQLite refuses the upgrade at once with SQLITE_BUSY — the busy_timeout is not
  #   consulted, as waiting could deadlock. Taking the lock up front makes it an ordinary wait under busy_timeout.
  module Sqlite
    module_function

    # Sequel connection options for hanami-db's gateway; busy_timeout_ms read and validated by Database.from_env
    def connection_options(busy_timeout_ms)
      { timeout: busy_timeout_ms, after_connect: method(:wal!) }
    end

    # Every new connection: WAL (persistent in the file; a no-op once set). A file system that cannot do WAL (or an
    # in-memory database) answers another mode — refused, never run on a journal the services would lock up on.
    def wal!(conn)
      mode = conn.get_first_value("PRAGMA journal_mode = WAL")
      return if mode == "wal"

      raise "SQLite refused WAL journal mode for #{conn.filename.inspect} (journal_mode is #{mode.inspect})"
    end

    # The Sequel database: every transaction BEGIN IMMEDIATE.
    def configure!(db)
      db.transaction_mode = :immediate
      db
    end
  end
end
