# frozen_string_literal: true

require "hanami/rake_tasks"
require "rake/testtask"

# + each auth provider directory's own tests (auth/<name>/test)
TEST_FILES = FileList["test/**/*_test.rb", "auth/*/test/**/*_test.rb"]

# serial, one process: `bundle exec rake test` (TEST=<file> for one file)
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = TEST_FILES
  t.warning = false
end
task default: :test

# The whole suite in one worker process per test file (test/support/parallel_runner.rb), on the database adapter the
# env names (DATABASE_ADAPTER: sqlite or postgresql): the schema is migrated once and copied per worker
# (test/support/test_databases.rb); each worker also gets its own attachments dir and launcher socket path. Every
# worker records line + branch coverage; the merged result is printed and fails below its floor
# (test/support/coverage.rb).
namespace :test do
  desc "Run the whole suite in parallel, one worker process per test file"
  task :parallel do
    require "tmpdir"
    require "fileutils"
    require_relative "test/support/parallel_runner"
    require_relative "test/support/coverage"
    require_relative "test/support/test_databases"
    dir = Dir.mktmpdir("busyyaks-test-")
    dbs = TestDatabases.new(dir).migrate_template!
    dbs.prepare(TEST_FILES.size)
    coverage = File.join(dir, "coverage")
    coverage_rb = File.expand_path("test/support/coverage.rb", __dir__)
    ok = ParallelRunner.run(
      files: TEST_FILES.to_a, libs: ["test"],
      boot: ->(i) { "require #{coverage_rb.dump}; TestCoverage.worker(#{coverage.dump}, #{i})" },
      env_for: lambda { |i|
        dbs.env(i).merge("ATTACHMENTS_DIR" => File.join(dir, "attachments-#{i}"),
                         "LAUNCHER_SOCKET" => File.join(dir, "launcher-#{i}.sock"))
      }
    )
    begin
      # one worker per file; a failed suite's coverage says nothing, so it is not measured
      TestCoverage.collate(coverage, TEST_FILES.size) if ok
    ensure
      dbs.cleanup
      FileUtils.rm_rf(dir)
    end
    abort "test:parallel failed" unless ok
  end
end
