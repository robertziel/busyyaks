# frozen_string_literal: true

require "digest"
require "json"
require "sequel"
require_relative "database"

module Busyyaks
  # One-time move of a SQLite database into an EMPTY PostgreSQL database (bin/db-copy-sqlite-to-postgres;
  # docs/DEPLOY.md § Switching SQLite → PostgreSQL). The SQLite file is opened read-only and never changed.
  #
  #   1. refuse: a target that is not PostgreSQL, a source that is not a file, a target with any table in it
  #   2. migrate the target with the app's migrations (`migrate`, a callable: bin/… runs `hanami db migrate --no-dump`)
  #   3. refuse: the source's applied migrations ≠ the target's, or its tables / columns ≠ the target's
  #   4. in ONE transaction: empty the rows the migrations seeded (the template board), copy every table in
  #      foreign-key order with its ids, set every id sequence past the copied max(id), then
  #   5. verify every table: row count + SHA-256 over all rows (SQLite: each raw value after #convert; PostgreSQL: as
  #      Sequel reads it — booleans, integers, floats, text — in primary-key order) equal on both sides. A failed
  #      insert or any difference raises inside the transaction: it rolls back and the target holds only what the
  #      migrations made
  #
  # SQLite values are read RAW (Sequel's type conversions off: they would turn a REAL 1.5 stored in an INTEGER column
  # into 1 on both sides of the comparison) and converted by the column's declared type, refusing anything that does
  # not fit exactly: boolean ← 0 / 1, integer ← an integer, float ← a number, string ← text. PostgreSQL refuses what
  # its columns cannot hold (an integer past int4) on insert. Either refusal rolls the move back.
  class DBCopy
    class Refused < StandardError; end
    class Mismatch < StandardError; end

    BATCH = 500
    Report = Data.define(:table, :rows, :sha256)

    def initialize(source:, target:, migrate:, out: $stdout)
      @source_path = source
      @target = target
      @migrate = migrate
      @out = out
    end

    # → [Report] (one per copied table, as verified)
    def run
      refuse!
      src = Sequel.connect("sqlite://#{@source_path}", readonly: true)
      src.conversion_procs.clear # raw values; #convert types them
      dst = Sequel.connect(@target.url, **@target.options)
      begin
        unless dst.tables.empty?
          raise Refused, "target #{@target.options[:database]} is not empty: #{dst.tables.sort.join(', ')}"
        end

        @migrate.call
        dst.disconnect
        tables = same_schema!(src, dst)
        order = fk_order(dst, tables)
        dst.transaction do
          dst.run("TRUNCATE #{order.map { dst.literal(_1) }.join(', ')} RESTART IDENTITY")
          order.each { |t| copy(src, dst, t) }
          order.each { |t| dst.reset_primary_key_sequence(t) if serial?(dst, t) }
          verify(src, dst, order)
        end
      ensure
        src.disconnect
        dst.disconnect
      end
    end

    private

    def refuse!
      unless @target.adapter == "postgresql"
        raise Refused, "the target must be DATABASE_ADAPTER=postgresql, not #{@target.adapter}"
      end
      raise Refused, "no SQLite file at #{@source_path}" unless File.file?(@source_path)
    end

    def same_schema!(src, dst)
      applied = ->(db) { db[:schema_migrations].select_order_map(:filename) }
      unless applied.(src) == applied.(dst)
        missing = applied.(dst) - applied.(src)
        extra = applied.(src) - applied.(dst)
        raise Refused, "the SQLite file is not at this code's schema: migrations missing #{missing}, unknown #{extra}"
      end
      tables = src.tables - [:schema_migrations]
      unless tables.sort == (dst.tables - [:schema_migrations]).sort
        raise Refused, "tables differ: SQLite #{tables.sort} vs PostgreSQL #{(dst.tables - [:schema_migrations]).sort}"
      end
      tables.each do |t|
        a = src.schema(t).map(&:first).sort
        b = dst.schema(t).map(&:first).sort
        raise Refused, "#{t}: columns differ: SQLite #{a} vs PostgreSQL #{b}" unless a == b
      end
      tables
    end

    # parents before children (the target's foreign keys); a cycle cannot be copied in order and is refused
    def fk_order(db, tables)
      deps = tables.to_h { |t| [t, db.foreign_key_list(t).map { _1[:table].to_sym }.uniq - [t]] }
      order = []
      until deps.empty?
        ready = deps.select { |_, d| (d - order).empty? }.keys.sort
        raise Refused, "foreign keys form a cycle among #{deps.keys.sort}" if ready.empty?

        order.concat(ready)
        ready.each { deps.delete(_1) }
      end
      order
    end

    def copy(src, dst, table)
      cols = src.schema(table).map(&:first)
      rows = source_rows(src, table)
      begin
        rows.each_slice(BATCH) { |slice| dst[table].import(cols, slice.map { |r| cols.map { r[_1] } }) }
      rescue Sequel::DatabaseError => e
        raise Mismatch, "#{table}: PostgreSQL refused a row (#{e.message.lines.first.strip})"
      end
      @out.puts format("copied %-20s %7d rows", table, rows.size)
    end

    def serial?(db, table)
      pk = db.schema(table).select { |_, c| c[:primary_key] }
      pk.size == 1 && pk[0][1][:type] == :integer && db.primary_key_sequence(table)
    end

    def verify(src, dst, tables)
      reports = tables.map do |t|
        a = fingerprint(src.schema(t), source_rows(src, t))
        b = fingerprint(dst.schema(t), ordered(dst, t))
        unless a == b
          raise Mismatch, "#{t}: SQLite #{a[0]} rows #{a[1][0, 12]} ≠ PostgreSQL #{b[0]} rows #{b[1][0, 12]}"
        end

        Report.new(table: t, rows: a[0], sha256: a[1])
      end
      reports.each { |r| @out.puts format("verified %-20s %7d rows  sha256 %s", r.table, r.rows, r.sha256[0, 16]) }
      reports
    end

    # [row count, SHA-256 of every row's values in primary-key order]
    def fingerprint(schema, rows)
      cols = schema.map(&:first).sort
      digest = Digest::SHA256.new
      rows.each { |r| digest << JSON.generate(cols.map { value(r[_1]) }) << "\n" }
      [rows.size, digest.hexdigest]
    end

    # every row, sorted in Ruby by the primary key (both databases' collations aside)
    def ordered(db, table, rows = nil)
      pk = db.schema(table).select { |_, c| c[:primary_key] }.map(&:first)
      pk = db.schema(table).map(&:first) if pk.empty?
      (rows || db[table].all).sort_by { |r| pk.map { |k| sort_key(r[k]) } }
    end

    def sort_key(v) = v.nil? ? [0, ""] : [1, v]

    # the SQLite rows, each value converted by its column's declared type (#convert) — before sorting, so a value of
    # the wrong type in a key column is refused, never compared — in primary-key order
    def source_rows(src, table)
      types = src.schema(table).to_h { |c, info| [c, info[:type]] }
      ordered(src, table, src[table].all.map { |r| r.to_h { |c, v| [c, convert(table, c, types.fetch(c), v)] } })
    end

    def convert(table, col, type, v)
      return nil if v.nil?

      ok = case type
           when :boolean then return(v == 1) if [0, 1].include?(v)
           when :integer then v.is_a?(Integer)
           when :float then return(v.to_f) if v.is_a?(Numeric)
           when :string then v.is_a?(String)
           end
      return v if ok

      raise Mismatch, "#{table}.#{col}: #{v.inspect[0, 40]} (#{v.class}) does not fit its #{type || 'undeclared'} column"
    end

    def value(v)
      case v
      when nil, true, false, Integer, Float then v
      when String then v.encoding == Encoding::BINARY ? v.unpack1("H*") : v
      else raise Mismatch, "a #{v.class} value (#{v.inspect[0, 40]}): no comparable form"
      end
    end
  end
end
