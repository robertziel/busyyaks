# frozen_string_literal: true

require "fileutils"
require "rake"
require "sequel"
require_relative "../../lib/busyyaks/database"

# One database per parallel test worker (Rakefile test:parallel), of the adapter the env names (DATABASE_ADAPTER):
# the schema is migrated ONCE into a template, then copied per worker.
#   sqlite:     <dir>/template.sqlite3 → <dir>/w<i>.sqlite3 (a file copy: the migrate process closed it, so it has no -wal)
#   postgresql: <POSTGRES_DB>_template → <POSTGRES_DB>_w<i> (CREATE DATABASE … TEMPLATE, on the server POSTGRES_* name;
#               the role needs CREATEDB), all dropped by #cleanup
class TestDatabases
  include FileUtils

  def initialize(dir, env = ENV)
    @dir = dir
    @setup = Busyyaks::Database.from_env(env)
  end

  # migrates the template; returns self
  def migrate_template!
    case @setup.adapter
    when "sqlite"
      @template = File.join(@dir, "template.sqlite3")
      migrate("SQLITE_PATH" => @template)
      raise "hanami db migrate left no #{@template}" unless File.file?(@template)
    when "postgresql"
      @template = "#{base}_template"
      admin { |db| recreate(db, @template) }
      # --no-dump: config/db/structure.sql is SQLite's schema (the committed one); pg_dump is not in the image
      migrate({ "POSTGRES_DB" => @template }, "--no-dump")
      @workers = []
    end
    self
  end

  # one copy of the template per worker, made before any starts (CREATE DATABASE … TEMPLATE refuses while another
  # copy of the same template is being made)
  def prepare(count)
    case @setup.adapter
    when "sqlite" then count.times { cp(@template, sqlite_path(_1)) }
    when "postgresql"
      admin { |db| count.times { recreate(db, worker_db(_1), template: @template) && @workers << worker_db(_1) } }
    end
  end

  # worker i's env
  def env(index)
    case @setup.adapter
    when "sqlite" then { "SQLITE_PATH" => sqlite_path(index) }
    when "postgresql" then { "POSTGRES_DB" => worker_db(index) }
    end
  end

  def cleanup
    return unless @setup.adapter == "postgresql"

    admin do |db|
      [*@workers, @template].compact.each { |d| db.run("DROP DATABASE IF EXISTS #{db.literal(Sequel.identifier(d))}") }
    end
  end

  private

  def base = @setup.options.fetch(:database)
  def sqlite_path(index) = File.join(@dir, "w#{index}.sqlite3")
  def worker_db(index) = "#{base}_w#{index}"

  def migrate(env, *args)
    Rake.sh(env, "bundle", "exec", "hanami", "db", "migrate", *args)
  end

  # the server's POSTGRES_DB: the connection that creates and drops the others
  def admin(&)
    Sequel.connect(@setup.url, **@setup.options, &)
  end

  def recreate(db, name, template: nil)
    id = db.literal(Sequel.identifier(name))
    db.run("DROP DATABASE IF EXISTS #{id}")
    db.run("CREATE DATABASE #{id}#{" TEMPLATE #{db.literal(Sequel.identifier(template))}" if template}")
    true
  end
end
