# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "sqlite3"
require "busyyaks/sqlite"

# The five services (web, mcp, scanner, github, notifier) are five processes writing one database. On SQLite their
# connection (config/providers/db.rb, lib/busyyaks/sqlite.rb) is WAL, busy_timeout from SQLITE_BUSY_TIMEOUT_MS, every
# transaction BEGIN IMMEDIATE. Without them, concurrent kanban_create calls failed with
# "SQLite3::BusyException: database is locked" (a deferred transaction that read, then could not upgrade to write).
# The suite runs on both adapters (CI ruby + ruby-pg): the writer processes' test holds on each.
class DatabaseConcurrencyTest < Minitest::Test
  include DBReset

  WRITERS = 6
  ITERATIONS = 40
  WRITER = File.expand_path("../support/database_writer.rb", __dir__)

  def db = Hanami.app["db.gateway"].connection

  def sqlite? = ENV.fetch("DATABASE_ADAPTER") == "sqlite"

  def test_the_connection_is_the_configured_adapter_with_its_settings
    if sqlite?
      assert_equal :sqlite, db.database_type
      assert_equal "wal", db.fetch("PRAGMA journal_mode").get(:journal_mode)
      assert_equal :immediate, db.transaction_mode
      assert_equal Integer(ENV.fetch("SQLITE_BUSY_TIMEOUT_MS")), db.fetch("PRAGMA busy_timeout").get(:timeout)
    else
      assert_equal :postgres, db.database_type
      assert_equal ENV.fetch("POSTGRES_DB"), db.get(Sequel.function(:current_database))
      held = db.transaction { db[:pg_locks].where(locktype: "advisory", objid: Busyyaks::Postgres::LOCK_KEY, pid: db.get(Sequel.function(:pg_backend_pid))).count }
      assert_equal 1, held, "every transaction holds the advisory lock"
      bound = db.transaction { db[:pg_settings].where(name: "lock_timeout").get(%i[setting unit]) }
      assert_equal [ENV.fetch("POSTGRES_LOCK_TIMEOUT_MS"), "ms"], bound
    end
  end

  # The wait for another writer's lock is bounded (SQLite busy_timeout · PostgreSQL lock_timeout): a writer behind a
  # transaction that holds the lock fails loudly after the bound, never waits forever. Two connections of the
  # suite's adapter, set up as the app's are, with a 300 ms bound.
  BOUND_MS = 300

  def test_a_writer_behind_a_held_lock_fails_after_the_bound
    setup = Busyyaks::Database.from_env(ENV.to_h.merge("SQLITE_BUSY_TIMEOUT_MS" => BOUND_MS.to_s,
                                                       "POSTGRES_LOCK_TIMEOUT_MS" => BOUND_MS.to_s))
    holder, waiter = Array.new(2) { Busyyaks::Database.configure!(Sequel.connect(setup.url, **setup.options), setup) }
    holding = Queue.new
    release = Queue.new
    t = Thread.new { holder.transaction { holder[:notes].count && holding << true && release.pop } }
    holding.pop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # in a thread with a deadline: an unbounded wait fails the test instead of hanging it
    w = Thread.new do
      waiter.transaction { waiter[:notes].count }
      nil
    rescue Sequel::DatabaseError => e
      e
    end
    flunk "the writer still waits after #{BOUND_MS * 10} ms: the lock wait is unbounded" unless w.join(BOUND_MS * 10 / 1000.0)
    waited = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    e = w.value
    assert_kind_of Sequel::DatabaseError, e, "the writer behind the held lock got through"
    assert_match(sqlite? ? /database is locked/ : /lock timeout/, e.message)
    assert_operator waited, :>=, BOUND_MS * 0.9, "it waited the bound first"
    assert_operator waited, :<, BOUND_MS * 10, "then failed, not waited on"
  ensure
    release&.push(true)
    t&.join
    w&.kill
    [holder, waiter].compact.each(&:disconnect)
  end

  def test_a_database_that_cannot_be_wal_is_refused
    mem = SQLite3::Database.new(":memory:")
    e = assert_raises(RuntimeError) { Busyyaks::Sqlite.wal!(mem) }
    assert_match(/refused WAL journal mode.*"memory"/, e.message)
  ensure
    mem&.close
  end

  # Separate processes, like the services: each boots the app, opens its own connection, and all start writing at
  # the same moment. Every create + comment must land; not one "database is locked".
  def test_concurrent_writer_processes_never_hit_database_is_locked
    store.upsert_project(slug: "g/r", path: "/nonexistent/g/r", remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    Busyyaks::Kanban.store.create(slug: "g/r", title: "seed: the board exists before the writers start", by: "seed")
    writers = []
    Dir.mktmpdir("sqlite-writers-") do |dir|
      go = File.join(dir, "go")
      writers = Array.new(WRITERS) do |i|
        stdin, stdout, wait = Open3.popen2e(RbConfig.ruby, WRITER, go, "g/r", ITERATIONS.to_s, "writer-#{i}")
        stdin.close
        [stdout, wait]
      end
      # every writer booted and connected before any starts: they write at the same moment
      writers.each { |stdout, wait| assert_ready(stdout, wait) }
      File.write(go, "")
      deadline = now + WRITE_SECONDS
      results = writers.map do |stdout, wait|
        output = read_until_eof(stdout, wait, deadline)
        assert wait.value.success?, "a writer process failed:\n#{output}"
        JSON.parse(output.lines.last)
      end
      errors = results.flat_map { _1["errors"] }
      assert_empty errors, "#{errors.size} of #{WRITERS * ITERATIONS} writes failed (#{WRITERS} processes x " \
                           "#{ITERATIONS} create+comment):\n#{errors.tally.map { |m, n| "#{n}x #{m}" }.join("\n")}"
      assert_equal WRITERS * ITERATIONS, results.sum { _1["done"] }
    end
    assert_equal (WRITERS * ITERATIONS) + 1, db[:cards].where(project_slug: "g/r").count
    assert_equal WRITERS * ITERATIONS, db[:card_activity].where(kind: "comment").count
    positions = db[:cards].where(project_slug: "g/r").select_map(:position)
    assert_equal positions.uniq.size, positions.size, "Store#create's count-then-insert ran one writer at a time"
  ensure
    # a failed assertion never leaves a writer waiting for the go file
    writers&.each do |_, wait|
      Process.kill("KILL", wait.pid) if wait.alive?
    rescue Errno::ESRCH # exited between alive? and kill: nothing to stop — never masks the test's own failure
      nil
    end
  end

  BOOT_SECONDS = 60    # each writer's boot, until it says "ready"
  WRITE_SECONDS = 120  # all writers' create+comment loops together (they take ~1 s); past it they are killed

  private

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A writer's whole output once it exits; one still writing at the deadline is killed and the test fails, never hangs.
  def read_until_eof(stdout, wait, deadline)
    output = +""
    loop do
      left = deadline - now
      unless left.positive? && stdout.wait_readable(left)
        Process.kill("KILL", wait.pid) if wait.alive?
        flunk "writer #{wait.pid} still writing after #{WRITE_SECONDS}s:\n#{output}"
      end
      chunk = stdout.read_nonblock(65_536, exception: false)
      break if chunk.nil?

      output << chunk unless chunk == :wait_readable
    end
    stdout.close
    output
  end

  # Lines before "ready" (a gem's warning on stderr) are kept for the failure message. A writer that has not said
  # ready by the deadline is interrupted, so its backtrace says where it hung.
  def assert_ready(stdout, wait)
    deadline = now + BOOT_SECONDS
    seen = +""
    while (left = deadline - now).positive? && stdout.wait_readable(left)
      line = stdout.gets or break
      return if line.chomp == "ready"

      seen << line
    end
    Process.kill("INT", wait.pid) if wait.alive?
    flunk "writer #{wait.pid} did not boot in #{BOOT_SECONDS}s:\n#{seen}#{stdout.read}"
  end
end
