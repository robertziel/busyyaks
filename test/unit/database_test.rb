# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/busyyaks/database"

# DATABASE_ADAPTER and its keys (lib/busyyaks/database.rb): explicit, validated, no default.
class DatabaseTest < Minitest::Test
  SQLITE = { "DATABASE_ADAPTER" => "sqlite", "SQLITE_PATH" => "/data/b.sqlite3", "SQLITE_BUSY_TIMEOUT_MS" => "15000" }.freeze
  PG = { "DATABASE_ADAPTER" => "postgresql", "POSTGRES_HOST" => "/var/run/postgresql", "POSTGRES_PORT" => "5432",
         "POSTGRES_DB" => "busyyaks", "POSTGRES_USER" => "yak", "POSTGRES_PASSWORD" => "s3cret",
         "POSTGRES_LOCK_TIMEOUT_MS" => "15000", }.freeze

  def load(env) = Busyyaks::Database.from_env(env)

  def refused(env, pattern)
    e = assert_raises(Busyyaks::Database::Invalid) { load(env) }
    assert_match pattern, e.message
  end

  def test_sqlite
    s = load(SQLITE)
    assert_equal "sqlite", s.adapter
    assert_equal "sqlite:///data/b.sqlite3", s.url
    assert_equal 15_000, s.options[:timeout]
    assert_equal 15_000, s.lock_timeout_ms
    assert s.options[:after_connect], "WAL is set on every connection"
  end

  def test_postgresql_keeps_the_password_out_of_the_url
    s = load(PG.merge("SQLITE_PATH" => "", "SQLITE_BUSY_TIMEOUT_MS" => ""))
    assert_equal "postgresql", s.adapter
    assert_equal "postgres:///busyyaks", s.url
    assert_equal({ host: "/var/run/postgresql", port: 5432, database: "busyyaks", user: "yak", password: "s3cret" }, s.options)
    refute_includes s.url, "s3cret"
    assert_equal 15_000, s.lock_timeout_ms
  end

  def test_no_default_adapter_and_no_unknown_one
    refused({}, /DATABASE_ADAPTER is required/)
    refused({ "DATABASE_ADAPTER" => "" }, /DATABASE_ADAPTER is empty/)
    refused({ "DATABASE_ADAPTER" => "mysql" }, /must be one of sqlite, postgresql, got "mysql"/)
  end

  def test_every_key_of_the_adapter_is_required
    %w[SQLITE_PATH].each { |k| refused(SQLITE.except(k), /#{k} is required/) }
    refused(SQLITE.except("SQLITE_BUSY_TIMEOUT_MS"), /SQLITE_BUSY_TIMEOUT_MS is required/)
    refused(SQLITE.merge("SQLITE_PATH" => "data/b.sqlite3"), /SQLITE_PATH must be an absolute path/)
    %w[POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_LOCK_TIMEOUT_MS].each do |k|
      refused(PG.except(k), /#{k} is required/)
      refused(PG.merge(k => " "), /#{k} is empty/)
    end
    %w[0 65536 54x].each { |port| refused(PG.merge("POSTGRES_PORT" => port), /POSTGRES_PORT must be a port number/) }
    %w[0 -5 5s 1.5].each do |bad|
      refused(SQLITE.merge("SQLITE_BUSY_TIMEOUT_MS" => bad), /SQLITE_BUSY_TIMEOUT_MS must be a positive integer/)
      refused(PG.merge("POSTGRES_LOCK_TIMEOUT_MS" => bad), /POSTGRES_LOCK_TIMEOUT_MS must be a positive integer/)
    end
  end

  def test_database_url_is_refused_not_ignored
    refused(SQLITE.merge("DATABASE_URL" => "sqlite:///x"), /DATABASE_URL is not read/)
  end
end
