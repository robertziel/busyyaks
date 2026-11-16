# frozen_string_literal: true

require "etc"
require "open3"
require "rbconfig"
require_relative "../../lib/busyyaks/clock"

# Runs minitest files in parallel worker PROCESSES: one per test file. Most of the suite waits on
# I/O (SQLite, sockets), not CPU, so capping workers at the CPU count only queued files behind each other; the OS shares
# the CPUs between the processes, and the wall clock becomes the slowest file's. Each worker is a fresh `ruby`
# loading its files, with the environment `env_for.(i)` gives it (its own database, sockets, dirs), so nothing a test
# touches is shared. Every worker's result is
# collected; a failed or crashed worker fails the run and its whole output is printed. The same files run as under
# `rake test`, only spread out — the totals line proves the count.
module ParallelRunner
  SUMMARY = /^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/
  LOAD = "ARGV.shift(ARGV.size).each { |f| require File.expand_path(f) }"
  Result = Struct.new(:index, :files, :status, :output, :counts, :seconds)

  module_function

  # The CPUs this process may run on (sched_getaffinity on Linux — a container's cpuset, not the host's count); reported only.
  def cpus = Etc.nprocessors

  def balance(files, n)
    buckets = Array.new(n) { [] }
    loads = Array.new(n, 0)
    files.sort_by { |f| [-File.size(f), f] }.each do |f|
      i = loads.index(loads.min)
      buckets[i] << f
      loads[i] += File.size(f)
    end
    buckets.reject(&:empty?)
  end

  # files: the test files · libs: -I dirs · env_for: worker index → its ENV additions · prepare: called with the index
  # before that worker starts (e.g. copy its database) · boot: worker index → Ruby code the worker runs before it loads
  # its files (e.g. start coverage). Returns true when every worker passed.
  def run(...) = run_results(...).then { |results| results.all? { passed?(_1) } }

  # The same run, returning every worker's Result (each already reported to `out`): the flake gate counts them per file.
  # max: at most that many workers at once, the rest queue (nil = every one at once)
  def run_results(files:, libs:, env_for:, prepare: nil, boot: nil, out: $stdout, max: nil)
    raise ArgumentError, "no test files" if files.empty?

    buckets = balance(files, files.size)
    out.puts "parallel: #{files.size} files in #{buckets.size} workers (#{cpus} CPUs#{max ? ", #{max} at once" : ''})"
    queue = Queue.new
    buckets.each_with_index { |bucket, i| queue << [bucket, i] }
    queue.close
    results = []
    lock = Mutex.new
    _, wall = Busyyaks::Clock.stopwatch do
      Array.new([max || buckets.size, buckets.size].min) do
        Thread.new do
          loop do
            fs, i = queue.pop
            break unless fs

            r = run_worker(i, fs, libs, env_for, prepare, boot)
            lock.synchronize { results << r }
          end
        end
      end.each(&:join)
    end
    results.sort_by!(&:index)
    report(results, wall, out)
    results
  end

  def passed?(r) = r.status&.success? && r.counts && r.counts[2].zero? && r.counts[3].zero?

  # true when every worker passed. Runs the host failed are named apart ("infrastructure"): red all the same, never read
  # as a red test
  def verdict(results, out:)
    report_infrastructure(results.reject { passed?(_1) }.select { infrastructure?(_1) }, out, "parallel")
    results.all? { passed?(_1) }
  end

  def report_infrastructure(infra, out, what)
    infra.each { |r| out.puts "#{what}: infrastructure: #{r.files.join(' ')} did not run cleanly — #{infrastructure?(r)}" }
    out.puts "#{what}: #{infra.size} run(s) hit the host's limits — not a test result" unless infra.empty?
  end

  # the host failed the run, not the test (a task limit): no worker process, no minitest
  # summary, or a resource error in its output. The reason, or nil
  RESOURCE = Regexp.union("Resource temporarily unavailable", "Cannot fork", "Errno::EAGAIN", "Errno::ENOMEM",
                          "failed to allocate memory", "Cannot allocate memory")
  def infrastructure?(r)
    return "the worker process did not start (#{r.output.lines.first&.strip})" if r.status.nil?
    return "it ran out of a host resource: #{r.output[RESOURCE]}" if r.output.match?(RESOURCE)

    "it ended (#{r.status.inspect}) without a minitest summary" unless r.counts
  end

  def run_worker(index, files, libs, env_for, prepare, boot)
    (output, status), seconds = Busyyaks::Clock.stopwatch do
      prepare&.call(index)
      # the files leave ARGV before minitest parses it (as its own options) at exit
      cmd = [RbConfig.ruby, *libs.flat_map { ["-I", _1] }, *(boot ? ["-e", boot.call(index)] : []), "-e", LOAD, *files]
      Open3.capture2e(env_for.call(index), *cmd)
    end
    counts = output.scan(SUMMARY).last&.map(&:to_i)
    Result.new(index, files, status, output, counts, seconds)
  rescue StandardError => e
    Result.new(index, files, nil, "worker #{index} did not run: #{e.class}: #{e.message}", nil, 0)
  end

  def report(results, wall, out)
    failed = results.reject { passed?(_1) }
    failed.each do |r|
      out.puts "", "── worker #{r.index} FAILED (#{r.status&.exitstatus.inspect}) · #{r.files.join(' ')} ──", r.output
    end
    results.each do |r|
      c = r.counts ? format("%d runs, %d assertions, %d failures, %d errors, %d skips", *r.counts) : "no summary"
      out.puts format("worker %2d  %5.1fs  %3d files  %s", r.index, r.seconds, r.files.size, c)
    end
    totals = results.filter_map(&:counts).transpose.map(&:sum)
    totals = [0, 0, 0, 0, 0] if totals.empty?
    out.puts format("TOTAL %d runs, %d assertions, %d failures, %d errors, %d skips · %d workers · %.1fs%s",
                    *totals, results.size, wall, failed.empty? ? "" : " · #{failed.size} worker(s) FAILED")
    failed.empty?
  end
end
