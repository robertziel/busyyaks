# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"

# Busyyaks::Clock: the one reader of the time, and the seam a test stubs. Its real reads are taken in a
# child process — a test reads no real clock itself (test/unit/no_real_clock_test.rb, no exception for this file).
class ClockTest < Minitest::Test
  CHILD = <<~RUBY
    require "json"
    require #{File.expand_path('../../lib/busyyaks/clock', __dir__).dump}
    c = Busyyaks::Clock
    a = c.monotonic
    now = c.now
    puts JSON.generate(now: now.class.name, epoch: c.epoch, now_i: now.to_i, today: c.today.iso8601,
                       now_date: now.to_date.iso8601, mono: a.class.name, mono_up: c.monotonic >= a)
  RUBY

  def test_it_reads_the_wall_and_the_monotonic_clock
    out, err, st = Open3.capture3(RbConfig.ruby, "-e", CHILD)
    assert st.success?, err
    r = JSON.parse(out)
    assert_equal %w[Time Float], r.values_at("now", "mono")
    assert_includes [r["now_i"], r["now_i"] + 1], r["epoch"], "epoch is the wall clock in seconds"
    assert_includes [r["now_date"], (Date.parse(r["now_date"]) + 1).iso8601], r["today"], "today is now's date"
    assert r["mono_up"], "monotonic never goes back"
  end

  def test_epoch_and_today_follow_a_stubbed_now
    t = Time.at(1_800_000_000).utc
    Busyyaks::Clock.stub(:now, t) do
      assert_equal 1_800_000_000, Busyyaks::Clock.epoch
      assert_equal Date.new(2027, 1, 15), Busyyaks::Clock.today
    end
  end
end
