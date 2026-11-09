# frozen_string_literal: true

module Busyyaks
  # Is the last scan fit to report from? The scanner scans, then sleeps SCAN_INTERVAL_SECONDS (.env, the scanner's own
  # value), so a healthy one finishes a scan every interval + scan duration. Stale = finished longer ago than
  # STALE_AFTER × interval + that scan's own duration (started_at..finished_at) capped at one interval — a long but
  # healthy scan is not stale, a stopped scanner is, and a row whose duration is absurd (started_at 0, a 20 h scan)
  # never stretches the limit past STALE_AFTER + 1 intervals: stale when now − finished_at > 3 × interval +
  # min(duration, interval). A row with no start (started_at missing / ≤ 0) or a negative duration is stale too, and
  # so is a finished_at more than FUTURE_SLACK seconds ahead of now (a clock problem: its age says nothing).
  # Used by McpServer (daily_facts / whats_new `last_scan`) and bin/daily-report.
  # Pure Ruby: bin/daily-report loads this file alone.
  module ScanFreshness
    STALE_AFTER = 3
    FUTURE_SLACK = 60

    module_function

    # → the last_scan JSON: finished_at (ISO), repos, error, age_seconds, duration_seconds, stale, stale_reason
    def json(scan, interval:, now:)
      return nil unless scan

      finished = scan[:finished_at].to_i
      started = scan[:started_at].to_i
      raw = finished - started
      duration = raw.clamp(0, interval)
      age = now.to_i - finished
      limit = (STALE_AFTER * interval) + duration
      reason = if started <= 0 then "the scan row has no start time (started_at #{scan[:started_at].inspect})"
               elsif raw.negative? then "the scan row started #{-raw} s after it finished"
               elsif age < -FUTURE_SLACK then "scan time in the future (clock): finished_at is #{-age} s ahead of now"
               elsif age > limit
                 "the last scan finished #{age} s ago (at #{Time.at(finished).utc.iso8601}): older than #{STALE_AFTER} × " \
                   "SCAN_INTERVAL_SECONDS + its duration capped at one interval, #{duration} s (#{limit} s) — " \
                   "the scanner is not running"
               end
      { finished_at: Time.at(finished).utc.iso8601, repos: scan[:repos], error: scan[:error], age_seconds: age,
        duration_seconds: duration, stale: !reason.nil?, stale_reason: reason, }
    end

    # last_scan as daily_facts returns it (string keys) → nil = fine, else why a report must not be made from it
    def refusal(last_scan)
      return "no scan has finished yet" if last_scan.nil?
      return "the last scan failed: #{last_scan['error']}" if last_scan["error"]
      return nil unless last_scan["stale"]

      "scan stale: #{last_scan['stale_reason']}"
    end
  end
end
