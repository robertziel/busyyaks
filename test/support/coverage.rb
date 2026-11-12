# frozen_string_literal: true

require "simplecov"

# Line + branch coverage of the parallel suite. `rake test:parallel` boots every worker process with
# `TestCoverage.worker` before it loads its test files; each worker stores its own result (command name "worker <i>")
# under the run's tmpdir; the task then merges them with `TestCoverage.collate`, prints the merged figures and fails
# below FLOOR. Everything is written inside the run's tmpdir (the test container's tmpfs) and removed with it.
#
# Measured: every Ruby file under app/ config/ lib/ auth/ cli/, loaded by a test or not
# (an unloaded file counts as 0 % of its lines;
# SimpleCov 0.22 records no branches for a file that never loads, so its branches are not counted).
# Left out: the tests (test/, auth/<provider>/test/) and vendor/ (the engine copy is covered in its own repo, at its
# own floor). Nothing else is filtered and no file carries a :nocov: marker.
module TestCoverage
  ROOT = File.expand_path("../..", __dir__)
  # The floor = the merged figures, rounded DOWN to an integer: line 95.45 %, branch 84.76 % (12 runs, all
  # the same since migrations_test loads each migration once; without a deployment's own auth provider: 95.63 % / 85.18 %).
  # Raised when the suite covers more; never lowered.
  FLOOR = { line: 95, branch: 84 }.freeze

  # Prints the merged result in the CI log; no report files.
  class Summary
    def format(result)
      line, branch = result.coverage_statistics.values_at(:line, :branch)
      puts Kernel.format("coverage: line %.2f %% (%d / %d) · branch %.2f %% (%d / %d) · floor line %d %% · " \
                         "branch %d %% · %d files", line.percent, line.covered, line.total, branch.percent,
                         branch.covered, branch.total, FLOOR[:line], FLOOR[:branch], result.files.size)
    end
  end

  module_function

  def configure(dir)
    SimpleCov.root ROOT
    SimpleCov.coverage_dir dir
    SimpleCov.enable_coverage :branch
    SimpleCov.track_files "{app,config,lib,auth,cli}/**/*.rb"
    SimpleCov.add_filter %r{\A/test/}
    SimpleCov.add_filter %r{\A/auth/[^/]+/test/}
    SimpleCov.add_filter %r{\A/vendor/}
  end

  # In worker `index`, before any test file loads: measure, and at exit only store this worker's result.
  def worker(dir, index)
    configure(File.join(dir, "w#{index}"))
    SimpleCov.command_name "worker #{index}"
    SimpleCov.start
    SimpleCov.at_exit { SimpleCov.result }
  end

  # After the run: every worker's result, merged. A missing result fails (a worker that measured nothing would
  # otherwise just lower the total); so does a merged result that measured nothing (SimpleCov calls 0 / 0 lines
  # 100 %: a wrong root or a track pattern matching no file would pass any floor); below FLOOR SimpleCov exits non-zero.
  def collate(dir, workers)
    results = Dir[File.join(dir, "w*", ".resultset.json")]
    raise "coverage: #{results.size} worker results for #{workers} workers in #{dir}" unless results.size == workers

    configure(File.join(dir, "merged"))
    SimpleCov.formatter Summary
    SimpleCov.minimum_coverage FLOOR
    SimpleCov.at_exit { measured!(SimpleCov.result).format! }
    SimpleCov.collate(results)
  end

  # The merged result, unless it measured no file, no line or no branch.
  def measured!(result)
    stats = result.coverage_statistics
    empty = { files: result.files.size, lines: stats[:line].total, branches: stats[:branch].total }.select { _2.zero? }
    raise "coverage: nothing measured (#{empty.keys.join(', ')}: 0) under #{ROOT}" unless empty.empty?

    result
  end
end
