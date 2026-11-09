# frozen_string_literal: true

require "test_helper"
require "digest"
require "open3"
require "tmpdir"
require "busyyaks/db_copy"

# bin/db-copy-sqlite-to-postgres (lib/busyyaks/db_copy.rb): a SQLite file migrated by the app's migrations, rows in
# EVERY table, copied into an empty PostgreSQL database and verified. The target is a scratch database
# <POSTGRES_DB>_<name> on the test service's PostgreSQL (compose test-postgres, POSTGRES_*), whichever adapter the
# suite itself runs on.
class DBCopyTest < Minitest::Test
  ROWS = 3

  def setup
    @dir = Dir.mktmpdir("dbcopy")
    @source = File.join(@dir, "source.sqlite3")
    # the copy's target server, whichever adapter the suite runs on
    @env = ENV.to_h.merge("DATABASE_ADAPTER" => "postgresql")
  end

  def teardown
    drop(@scratch) if @scratch
    FileUtils.rm_rf(@dir)
  end

  def test_copies_every_table_into_an_empty_postgresql_and_verifies_it
    filled = fixture
    before = Digest::SHA256.file(@source).hexdigest
    target = scratch_target("copy")
    out = StringIO.new
    reports = copier(target, out: out).run
    assert_equal filled.keys.sort, reports.map(&:table).sort, "every table copied and verified"
    reports.each { |r| assert_equal filled.fetch(r.table), r.rows, r.table }
    assert_match(/verified cards\s+#{ROWS} rows  sha256 \h{16}/, out.string)
    assert_equal before, Digest::SHA256.file(@source).hexdigest, "the SQLite file is not changed"

    dst = Sequel.connect(target.url, **target.options)
    begin
      # booleans are PostgreSQL booleans; every id sequence continues after the copied ids
      assert_equal [false, true], dst[:commits].select_order_map(:mine).uniq.sort_by { _1 ? 1 : 0 }
      max = dst[:notes].max(:id)
      assert_equal max + 1, dst[:notes].insert(body: "after the copy", author: "t", created_at: 1)
      # the template board's rows are the SQLite file's, not a second seeded copy
      assert_equal 1, dst[:boards].where(project_slug: "").count
    ensure
      dst.disconnect
    end

    e = assert_raises(Busyyaks::DBCopy::Refused) { copier(target).run }
    assert_match(/is not empty/, e.message)
  end

  # a value that does not fit its column (REAL 1.5 in an INTEGER column — SQLite keeps it, PostgreSQL would round it;
  # text in an INTEGER key column — refused before the rows are sorted by it) is refused by the conversion; one
  # PostgreSQL cannot hold (past int4) by the insert — either way the transaction rolls back: migrated, nothing copied
  def test_a_value_postgresql_changes_or_refuses_rolls_the_copy_back
    cases = [[:notes, :created_at, 1.5, /notes.created_at: 1.5 \(Float\) does not fit its integer column/],
             [:gh_merged_prs, :number, "seven", /gh_merged_prs.number: "seven" \(String\) does not fit its integer column/],
             [:notes, :created_at, 2**40, /notes: PostgreSQL refused a row .*out of range/],]
    cases.each_with_index do |(table, col, bad, msg), i|
      @source = File.join(@dir, "bad#{i}.sqlite3")
      fixture
      src = Sequel.sqlite(@source)
      key = src.schema(table).find { |_, c| c[:primary_key] }.first
      rows = src[table].order(key).all
      # the bad value in a key column: the row shares every key column before it with another row, so sorting by the
      # key compares the bad value with an integer (the pre-#convert sort raised ArgumentError there)
      pk = src.schema(table).select { |_, c| c[:primary_key] }.map(&:first)
      same = pk.include?(col) ? pk.take_while { _1 != col } : []
      src[table].where(key => rows[0][key]).update(same.to_h { [_1, rows[1][_1]] }.merge(col => bad))
      src.disconnect
      target = scratch_target("bad")
      e = assert_raises(Busyyaks::DBCopy::Mismatch) { copier(target).run }
      assert_match msg, e.message
      dst = Sequel.connect(target.url, **target.options)
      begin
        # nothing of the SQLite file committed: only what the migrations seed (the template board, project_slug "")
        left = (dst.tables - [:schema_migrations]).to_h do |t|
          ds = dst[t]
          ds = ds.exclude(project_slug: "") if dst.schema(t).any? { |c, _| c == :project_slug }
          [t, ds.count]
        end
        assert_equal({}, left.reject { |_, n| n.zero? }, "nothing committed")
      ensure
        dst.disconnect
      end
    end
  end

  def test_refuses_a_file_at_another_schema_or_no_file
    fixture
    src = Sequel.sqlite(@source)
    src[:schema_migrations].where(filename: src[:schema_migrations].min(:filename)).delete
    src.disconnect
    target = scratch_target("schema")
    e = assert_raises(Busyyaks::DBCopy::Refused) { copier(target).run }
    assert_match(/not at this code's schema: migrations missing \["20261101000000/, e.message)

    never = -> { flunk "never migrates" }
    e = assert_raises(Busyyaks::DBCopy::Refused) do
      Busyyaks::DBCopy.new(source: File.join(@dir, "none.sqlite3"), target: target, migrate: never, out: StringIO.new).run
    end
    assert_match(/no SQLite file at/, e.message)
    sqlite = Busyyaks::Database.from_env(@env.merge("DATABASE_ADAPTER" => "sqlite"))
    e = assert_raises(Busyyaks::DBCopy::Refused) { Busyyaks::DBCopy.new(source: @source, target: sqlite, migrate: never).run }
    assert_match(/must be DATABASE_ADAPTER=postgresql, not sqlite/, e.message)
  end

  private

  def copier(target, out: StringIO.new)
    migrate = -> { migrate!("DATABASE_ADAPTER" => "postgresql", "POSTGRES_DB" => target.options.fetch(:database)) }
    Busyyaks::DBCopy.new(source: @source, target: target, migrate: migrate, out: out)
  end

  def migrate!(env)
    out, status = Open3.capture2e(env, "bundle", "exec", "hanami", "db", "migrate", "--no-dump")
    assert status.success?, "hanami db migrate failed:\n#{out}"
  end

  # the app's migrations into a SQLite file, then ROWS rows in every table (→ {table => rows})
  def fixture
    migrate!("DATABASE_ADAPTER" => "sqlite", "SQLITE_PATH" => @source)
    db = Sequel.sqlite(@source)
    tables = db.tables - [:schema_migrations]
    order = Busyyaks::DBCopy.allocate.send(:fk_order, db, tables)
    order.each { |t| fill(db, t) }
    counts = order.to_h { |t| [t, db[t].count] }
    db.disconnect
    counts.each { |t, n| assert_operator n, :>=, ROWS, "#{t} has rows" }
    counts
  end

  # values of every column type, a NULL in each nullable column of the last row, unicode / quotes / newlines in text,
  # foreign keys pointing at the parent's rows (which exist: tables are filled parents first)
  def fill(db, table)
    fks = db.foreign_key_list(table).to_h { |f| [f[:columns].first, f[:table]] }
    schema = db.schema(table)
    serial = schema.select { |_, c| c[:primary_key] }.then { |pk| pk.size == 1 && pk[0][1][:type] == :integer ? pk[0][0] : nil }
    ROWS.times do |i|
      row = schema.each_with_object({}) do |(col, info), h|
        next if col == serial

        last = i == ROWS - 1 && info[:allow_null] && !info[:primary_key]
        h[col] = if last then nil
                 elsif fks[col] then db[fks[col]].order(:id).offset(i % db[fks[col]].count).get(:id)
                 else sample(info[:type], table, col, i)
                 end
      end
      db[table].insert(row)
    end
  end

  def sample(type, table, col, i)
    case type
    when :integer then 1_700_000_000 + i
    when :boolean then i.even?
    when :float then 1.5 + (i / 10.0)
    else "#{table}.#{col} #{i} — zażółć ✓ 'q' \"d\"\nline"
    end
  end

  def scratch_target(suffix)
    @scratch = "#{@env.fetch('POSTGRES_DB')}_#{suffix}"
    drop(@scratch)
    admin { |a| a.run("CREATE DATABASE #{a.literal(Sequel.identifier(@scratch))}") }
    Busyyaks::Database.from_env(@env.merge("POSTGRES_DB" => @scratch))
  end

  def admin(&)
    setup = Busyyaks::Database.from_env(@env)
    Sequel.connect(setup.url, **setup.options, &)
  end

  def drop(name)
    admin { |a| a.run("DROP DATABASE IF EXISTS #{a.literal(Sequel.identifier(name))}") }
  end
end
