# frozen_string_literal: true

require "io/wait"
require_relative "../../lib/busyyaks/clock"

# Waiting on something outside the test process (a child process, a socket, a log line, another thread) — the suite's
# ONLY waits (test/unit/no_real_clock_test.rb): a test never sleeps, pauses or blocks with a timeout itself
# (no Queue#pop(timeout:), Thread#join(n), IO#wait_readable(n), IO.select(…, n), Timeout.timeout). Each helper polls a
# NON-blocking check every `every` s through Busyyaks::Clock.pause (the one caller of it), at most seconds / every times,
# then fails with `what`. The bound is a poll COUNT, never a clock read: a test may stub Busyyaks::Clock (to stand time
# still) and still wait here; a slow runner only waits longer, never reads a different answer. The bound is a hang
# guard only — an upper limit on how long something MAY take, never an assertion that something did NOT happen: an
# absence is asserted after the event that decides it. `what` names the wait in the failure (a Proc: read at that
# moment, e.g. a log's tail).
module Wait
  TimedOut = Class.new(StandardError)

  module_function

  # the block's first truthy value; TimedOut after the polls
  def for(what, seconds:, every: 0.05, &check)
    value = until?(seconds: seconds, every: every, &check)
    return value if value

    raise TimedOut, "waited #{(seconds / every).ceil} × #{every} s for #{what.respond_to?(:call) ? what.call : what}"
  end

  # the block's first truthy value, or nil after the polls (a loop that decides on its own what a long wait means)
  def until?(seconds:, every: 0.05)
    (seconds / every).ceil.times do
      value = yield
      return value if value

      Busyyaks::Clock.pause(every)
    end
    yield
  end

  # a Queue's next item
  def pop(queue, what, seconds:)
    self.for(what, seconds: seconds) do
      [queue.pop(true)]
    rescue ThreadError # empty
      nil
    end.first
  end

  # a thread's end (its exception re-raised, as Thread#join does) → the thread
  def join(thread, what, seconds:)
    self.for(what, seconds: seconds) { !thread.alive? }
    thread.join
  end

  # an IO with something to read (data, or its end) → the IO; readable? = the same, or false after the polls
  def readable(io, what, seconds:) = self.for(what, seconds: seconds) { io.wait_readable(0) && io }

  def readable?(io, seconds:) = until?(seconds: seconds) { io.wait_readable(0) && io } ? true : false

  # exactly `bytes` bytes, read as they arrive; EOFError when the stream ends first
  def read(io, bytes, what, seconds:)
    buf = +""
    self.for(what, seconds: seconds) do
      chunk = io.read_nonblock(bytes - buf.bytesize, exception: false)
      raise EOFError, "#{what}: the stream ended after #{buf.bytesize} of #{bytes} bytes" if chunk.nil?

      buf << chunk unless chunk == :wait_readable
      buf.bytesize == bytes && buf.b
    end
  end
end

# How long something took, asserted from BELOW only ("refused fast" at 3.02 s against
# a 3 s bound while every stage ran at once): a slower machine can only make a run longer, so a lower bound never goes
# red on a loaded runner, and an upper bound on real time is not something a test may state — it asserts what happened
# instead (the reason, the calls, the exit). `seconds` may be a Proc of the block's value (e.g. the seconds a refusal
# reports: it cannot have taken longer than the call). Returns the block's value.
module Elapsed
  module_function

  def at_least(seconds, what)
    value, took = Busyyaks::Clock.stopwatch { yield }
    bound = seconds.respond_to?(:call) ? seconds.call(value) : seconds
    raise Minitest::Assertion, "#{what}: took #{took.round(2)} s, expected at least #{bound} s" if took < bound

    value
  end
end
