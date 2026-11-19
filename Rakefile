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

# The whole suite in one worker process per test file (test/support/parallel_runner.rb), TEST_WORKERS (env, required) of
# them at a time — CI: the runner's CPUs (scripts/ci/runner.env: one process per file all at once ran a
# Jenkins agent out of tasks once builds ran side by side) — on the database adapter the
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
    workers = Integer(ENV.fetch("TEST_WORKERS"), 10)
    abort "test:parallel: TEST_WORKERS must be ≥ 1 (is #{workers})" unless workers.positive?
    results = ParallelRunner.run_results(
      files: TEST_FILES.to_a, libs: ["test"], max: workers,
      boot: ->(i) { "require #{coverage_rb.dump}; TestCoverage.worker(#{coverage.dump}, #{i})" },
      env_for: lambda { |i|
        dbs.env(i).merge("ATTACHMENTS_DIR" => File.join(dir, "attachments-#{i}"),
                         "LAUNCHER_SOCKET" => File.join(dir, "launcher-#{i}.sock"),
                         "WRITER_SOCKET" => File.join(dir, "writer-#{i}.sock"))
      }
    )
    ok = ParallelRunner.verdict(results, out: $stdout)
    begin
      # one worker per file; a failed suite's coverage says nothing, so it is not measured
      TestCoverage.collate(coverage, TEST_FILES.size) if ok
    ensure
      dbs.cleanup
      FileUtils.rm_rf(dir)
    end
    abort "test:parallel failed" unless ok
  end

  # The flake gate's repeats (scripts/ci/test.sh flake): every file in TEST_REPEAT_FILES (space-separated)
  # TEST_REPEAT_TIMES times, each run its own worker, TEST_REPEAT_WORKERS at once (the rest queue). All three required.
  # Any red run fails it, named per file: "flaky: <file> failed k/N". Coverage is the full suite's, not measured here.
  desc "Run TEST_REPEAT_FILES, each TEST_REPEAT_TIMES times, TEST_REPEAT_WORKERS runs at a time"
  task :repeat do
    require "tmpdir"
    require "fileutils"
    require_relative "test/support/parallel_runner"
    require_relative "test/support/test_databases"
    files = ENV.fetch("TEST_REPEAT_FILES").split
    times = Integer(ENV.fetch("TEST_REPEAT_TIMES"), 10)
    workers = Integer(ENV.fetch("TEST_REPEAT_WORKERS"), 10)
    abort "test:repeat: TEST_REPEAT_FILES is empty" if files.empty?
    abort "test:repeat: TEST_REPEAT_TIMES must be ≥ 1 (is #{times})" unless times.positive?
    abort "test:repeat: TEST_REPEAT_WORKERS must be ≥ 1 (is #{workers})" unless workers.positive?
    missing = files.reject { File.file?(_1) }
    abort "test:repeat: no such test file: #{missing.join(' ')}" unless missing.empty?
    runs = files.flat_map { |f| [f] * times }
    dir = Dir.mktmpdir("busyyaks-repeat-")
    dbs = TestDatabases.new(dir).migrate_template!
    dbs.prepare(runs.size)
    results = ParallelRunner.run_results(
      files: runs, libs: ["test"], max: workers,
      env_for: lambda { |i|
        dbs.env(i).merge("ATTACHMENTS_DIR" => File.join(dir, "attachments-#{i}"),
                         "LAUNCHER_SOCKET" => File.join(dir, "launcher-#{i}.sock"),
                         "WRITER_SOCKET" => File.join(dir, "writer-#{i}.sock"))
      }
    )
    # a run that did not run, or ran out of a host resource (a task / memory limit), says nothing about the test: it is
    # an INFRASTRUCTURE error, reported apart and red, never counted as a flaky run
    infra, red = results.reject { ParallelRunner.passed?(_1) }.partition { ParallelRunner.infrastructure?(_1) }
    ParallelRunner.report_infrastructure(infra, $stdout, "flake")
    red = red.flat_map(&:files).tally
    red.each { |f, k| puts "flaky: #{f} failed #{k}/#{times}" }
    verdict = red.empty? ? "every run green" : "#{red.size} file(s) red"
    verdict += " · #{infra.size} run(s) hit the host's limits" unless infra.empty?
    puts "flake: #{files.size} files × #{times}, #{workers} at once: #{verdict}"
    abort "test:repeat failed" unless red.empty? && infra.empty?
  ensure
    dbs&.cleanup
    FileUtils.rm_rf(dir) if dir
  end
end
