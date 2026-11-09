# frozen_string_literal: true

module Busyyaks
  # PostgreSQL connection settings (DATABASE_ADAPTER=postgresql; applied by Database.configure!).
  #
  # Every transaction takes one transaction-scoped advisory lock first, so transactions run one at a time — what
  # BEGIN IMMEDIATE gives on SQLite (lib/busyyaks/sqlite.rb). The wait is bounded like SQLite's busy_timeout: the
  # transaction sets `lock_timeout` (POSTGRES_LOCK_TIMEOUT_MS) before it asks for the lock, so a writer behind one that
  # holds it too long fails with "canceling statement due to lock timeout" instead of waiting forever. The bound holds
  # for every lock that transaction waits on. The kanban engine's writes read, then write in one
  # transaction (Store#create: count the column's cards, insert at that position); under PostgreSQL's READ COMMITTED
  # two of them at once read the same count and both insert at it. SERIALIZABLE would instead fail one of them,
  # which only a retry could hide. A statement outside a transaction is atomic on its own and takes no lock; nested
  # transactions are savepoints inside the locked one.
  module Postgres
    # the advisory lock's key (bigint): "busy" in ASCII; any other user of advisory locks on the database must not use it
    LOCK_KEY = 0x6275_7379

    # Sequel's hook for a transaction's BEGIN (private API; Sequel 5's shared postgres adapter)
    module SerializedTransactions
      attr_accessor :busyyaks_lock_timeout_ms

      private

      def begin_new_transaction(conn, opts)
        super
        log_connection_execute(conn, "SET LOCAL lock_timeout = #{Integer(busyyaks_lock_timeout_ms)}")
        log_connection_execute(conn, "SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
      end
    end

    module_function

    def configure!(db, lock_timeout_ms)
      db.extend(SerializedTransactions)
      db.busyyaks_lock_timeout_ms = lock_timeout_ms
      db
    end
  end
end
