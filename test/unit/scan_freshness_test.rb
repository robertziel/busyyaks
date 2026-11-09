# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/busyyaks/scan_freshness"

# bin/daily-report's gate: no report from a scan that is missing, failed or stale
class ScanFreshnessTest < Minitest::Test
  F = Busyyaks::ScanFreshness
  NOW = 1_000_000

  # a scan that took `took` s and finished `age` s ago; interval 60
  def scan(age, took: 5, error: nil)
    F.json({ started_at: NOW - age - took, finished_at: NOW - age, repos: 5, error: error }, interval: 60, now: NOW)
  end

  def test_stale_after_three_intervals_plus_the_scans_duration
    refute scan(185)[:stale]
    assert scan(186)[:stale]
    assert_equal [186, 5], scan(186).values_at(:age_seconds, :duration_seconds)
  end

  # a long but healthy scan: 50 s, and 1.5 × the interval (90 s, its term capped at 60)
  def test_a_long_healthy_scan_is_not_stale
    refute scan(230, took: 50)[:stale]
    assert scan(231, took: 50)[:stale]
    refute scan(240, took: 90)[:stale]
  end

  # the duration term is capped at one interval: a 20 h scan finished 19 h ago, or a row with started_at 0 finished
  # 30 days ago, is stale
  def test_an_absurd_duration_never_stretches_the_limit
    assert scan(19 * 3600, took: 20 * 3600)[:stale]
    assert_equal 60, scan(19 * 3600, took: 20 * 3600)[:duration_seconds]
    zero = F.json({ started_at: 0, finished_at: NOW - (30 * 86_400), repos: 1, error: nil }, interval: 60, now: NOW)
    assert zero[:stale]
    recent_zero = F.json({ started_at: 0, finished_at: NOW - 10, repos: 1, error: nil }, interval: 60, now: NOW)
    assert_match(/no start time/, recent_zero[:stale_reason], "no start = stale, however recent")
    missing = F.json({ started_at: nil, finished_at: NOW - 10, repos: 1, error: nil }, interval: 60, now: NOW)
    assert missing[:stale]
    backwards = F.json({ started_at: NOW - 5, finished_at: NOW - 10, repos: 1, error: nil }, interval: 60, now: NOW)
    assert_match(/started 5 s after it finished/, backwards[:stale_reason])
    refute scan(240, took: 20 * 3600)[:stale], "3 × 60 + the capped 60 = 240 s"
    assert scan(241, took: 20 * 3600)[:stale]
  end

  def test_a_scan_time_in_the_future_is_stale
    refute scan(-60)[:stale], "a little clock skew is fine"
    s = scan(-61)
    assert s[:stale]
    assert_match(/scan time in the future \(clock\)/, s[:stale_reason])
  end

  def test_refusals
    as_json = ->(h) { h&.transform_keys(&:to_s) }
    assert_nil F.refusal(as_json.(scan(30)))
    assert_match(/no scan has finished/, F.refusal(nil))
    assert_match(/the last scan failed: boom/, F.refusal(as_json.(scan(30, error: "boom"))))
    assert_match(/\Ascan stale: the last scan finished 4000 s ago .*5 s \(185 s\)/, F.refusal(as_json.(scan(4000))))
  end
end
