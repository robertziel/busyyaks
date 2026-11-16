# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../support/parallel_runner"

# test/support/parallel_runner.rb's bound (the flake gate's: one test process per runner CPU): with max: n
# no more than n workers run at once, every file still runs, and the results come back in worker order
class ParallelRunnerTest < Minitest::Test
  # a "test file" that counts how many of its kind run at once (under flock), stays a moment, and prints a summary
  WORKER = <<~'RUBY'
    count = File.join(ENV.fetch("RUN_DIR"), "count")
    bump = lambda do |by|
      File.open(count, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        cur, top = f.read.split.map(&:to_i).then { |c, t| [c.to_i + by, [t.to_i, c.to_i + by].max] }
        f.rewind; f.truncate(0); f.write("#{cur} #{top}")
      end
    end
    bump.(1)
    Kernel.sleep(0.3)
    bump.(-1)
    puts "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
  RUBY

  def test_max_bounds_the_workers_at_once_and_every_file_runs
    Dir.mktmpdir do |dir|
      files = Array.new(6) { |i| File.join(dir, "w#{i}_test.rb").tap { File.write(_1, WORKER) } }
      out = StringIO.new
      results = ParallelRunner.run_results(files: files, libs: [], env_for: ->(_) { { "RUN_DIR" => dir } }, max: 2, out: out)

      assert_equal (0..5).to_a, results.map(&:index)
      assert_equal files.sort, results.flat_map(&:files).sort
      assert results.all? { ParallelRunner.passed?(_1) }, out.string
      # at most max at once (how many overlap is the scheduler's: on a loaded runner they may run one after the other)
      assert_includes 1..2, File.read(File.join(dir, "count")).split.last.to_i, "never more than max at once"
      assert_match "(#{ParallelRunner.cpus} CPUs, 2 at once)", out.string
    end
  end

  # a run the host failed is an infrastructure error, never a flaky test (a task limit)
  def test_a_run_the_host_failed_is_told_apart_from_a_red_test
    r = ->(status, output) { ParallelRunner::Result.new(0, ["a_test.rb"], status, output, output[ParallelRunner::SUMMARY] ? [1, 1, 1, 0, 0] : nil, 0) }
    ok = Process::Status.wait(Process.spawn("true"))
    bad = Process::Status.wait(Process.spawn("false"))

    assert_match "did not start", ParallelRunner.infrastructure?(r.(nil, "worker 3 did not run: ThreadError: x"))
    assert_match "ran out of a host resource: Resource temporarily unavailable",
                 ParallelRunner.infrastructure?(r.(bad, "1 runs, 1 assertions, 0 failures, 1 errors, 0 skips\n" \
                                                        "ThreadError: can't create Thread: Resource temporarily unavailable"))
    assert_match "without a minitest summary", ParallelRunner.infrastructure?(r.(bad, "Killed"))
    assert_match "Cannot fork", ParallelRunner.infrastructure?(r.(bad, "1 runs, 1 assertions, 0 failures, 1 errors, 0 skips\n" \
                                                                    "git-upload-pack '/x': 1: Cannot fork"))
    assert_nil ParallelRunner.infrastructure?(r.(bad, "1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"))
    assert_nil ParallelRunner.infrastructure?(r.(ok, "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"))
  end

  def test_the_verdict_names_runs_the_host_failed_apart
    ok = Process::Status.wait(Process.spawn("true"))
    good = ParallelRunner::Result.new(0, ["a_test.rb"], ok, "", [1, 1, 0, 0, 0], 0)
    lost = ParallelRunner::Result.new(1, ["b_test.rb"], nil, "worker 1 did not run: ThreadError: x", nil, 0)
    out = StringIO.new

    refute ParallelRunner.verdict([good, lost], out: out)
    assert_match "parallel: infrastructure: b_test.rb did not run cleanly — the worker process did not start", out.string
    assert_match "parallel: 1 run(s) hit the host's limits — not a test result", out.string
    assert ParallelRunner.verdict([good], out: StringIO.new)
  end
end
