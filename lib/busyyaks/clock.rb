# frozen_string_literal: true

require "date"

module Busyyaks
  # The one place busyyaks's code reads the time. Every wall-clock and monotonic read goes through here, so a
  # test can stand the clock still or move it (`Busyyaks::Clock.stub(:monotonic, t) { … }`) instead of racing it: the
  # suite runs on the public runner's 4 CPUs and on a 32-CPU host alike, and a test that measures a window against the
  # real clock passes on one and fails on the other. test/unit/no_real_clock_test.rb fails on any other read.
  # Stdlib only: the host programs (bin/launcher) load it too.
  module Clock
    module_function

    # the wall clock, a Time (local zone)
    def now = Time.now

    # the wall clock in whole seconds since the epoch
    def epoch = now.to_i

    # today's date in the local zone
    def today = now.to_date

    # seconds on the monotonic clock: durations, cache windows, deadlines
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The test suite's two sanctioned uses of real time (test/unit/no_real_clock_test.rb allows these two names and
    # nothing else): a pause while waiting on another process (Wait.for), and a stopwatch that returns the block's
    # value and the seconds it took (Elapsed.at_least, the runner's report)
    def pause(seconds) = sleep(seconds)

    def stopwatch
      started = monotonic
      value = yield
      [value, monotonic - started]
    end
  end
end
