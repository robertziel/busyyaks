# frozen_string_literal: true

require "json"
require "yaml"
require "monitor"
require_relative "clock"

module Busyyaks
  # The services' timing: how often the scanner scans, the github service collects and polls PRs, the notifier
  # delivers and watches, and the watchdog's grace — once .env keys, now revisions in the
  # DATABASE (table runtime_settings: the newest row is the current one, every earlier one stays as history), edited
  # on Settings → Runtime or with bin/runtime-settings. The migration seeds revision 1 from config/runtime.template.yml
  # (the values .env.example shipped); a deployment that ran other values imports its old .env lines
  # (bin/runtime-settings import-env < .env). Every reader asks the CURRENT revision at each use (a service at each
  # loop turn, the web per request): a save applies without a restart.
  #
  # A revision is all of KEYS, each a whole number of seconds in BOUNDS, no other key, and the notifier's watch pass
  # fits inside the CI poll window (watch_fits): checked on every save, so a stored revision always runs.
  module RuntimeSettings
    TABLE = :runtime_settings
    TEMPLATE = File.expand_path("../../config/runtime.template.yml", __dir__)
    # key => [the .env key it replaces, what it times]
    KEYS = {
      "scan_interval_seconds" => ["SCAN_INTERVAL_SECONDS", "scanner: seconds between repo scans"],
      "github_interval_seconds" => ["GITHUB_INTERVAL_SECONDS", "github: seconds between network collections"],
      "github_ci_interval_seconds" => ["GITHUB_CI_INTERVAL_SECONDS", "github: seconds between PR / CI polls"],
      "notifier_interval_seconds" => ["NOTIFIER_INTERVAL_SECONDS", "notifier: seconds between ping deliveries"],
      "notifier_watch_seconds" => ["NOTIFIER_WATCH_SECONDS", "notifier: seconds between watch passes"],
      "watchdog_grace_seconds" => ["WATCHDOG_GRACE_SECONDS", "watchdog: seconds a gone session keeps its cards"],
    }.freeze
    ENV_KEYS = KEYS.transform_values(&:first).invert.freeze # "SCAN_INTERVAL_SECONDS" => "scan_interval_seconds"
    BOUNDS = (1..86_400) # a whole number of seconds, at most a day

    class Error < StandardError; end
    # a save based on a revision that is no longer the newest (someone saved in between): reload, then save again
    class Conflict < Error; end
    # the document is refused: a key missing / unknown / not a whole number in BOUNDS, or the watch pass too slow
    class Refused < Error; end
    # no revision at all (the migration seeds one: the table was emptied by hand)
    class Missing < Error; end

    module_function

    # A revision's document validated → {scan_interval_seconds: 60, …} (symbol keys, frozen).
    def values!(doc)
      raise Refused, "runtime settings must be an object {#{KEYS.keys.join(', ')}}" unless doc.is_a?(Hash)

      missing = KEYS.keys - doc.keys
      raise Refused, "missing #{missing.join(', ')}" if missing.any?

      unknown = doc.keys - KEYS.keys
      raise Refused, "unknown #{unknown.join(', ')} (known: #{KEYS.keys.join(', ')})" if unknown.any?

      KEYS.each_key do |k|
        v = doc[k]
        next if v.is_a?(Integer) && BOUNDS.cover?(v)

        raise Refused, "#{k} must be a whole number of seconds, #{BOUNDS.min}..#{BOUNDS.max} (got #{v.inspect})"
      end
      watch_fits!(doc)
      doc.transform_keys(&:to_sym).freeze
    end

    # The CI poll window: how long the github service keeps polling a request (CiChecks.wanted_for: 10 × the poll
    # interval). The notifier's watch pass re-asks every gated card's approval checks; a pass slower than
    # the window lets a request lapse between two passes and Approve waits for a CI read again. The watch runs inside
    # the deliver loop (bin/notifier), which sleeps notifier_interval_seconds between turns and runs the watch on the
    # first turn at least notifier_watch_seconds after the last: the real period is the watch rounded UP to whole turns.
    def watch_period(watch, interval) = (watch + interval - 1) / interval * interval

    def watch_fits!(doc)
      window = 10 * doc["github_ci_interval_seconds"]
      period = watch_period(doc["notifier_watch_seconds"], doc["notifier_interval_seconds"])
      return if period < window

      raise Refused, "a watch pass every #{period} s (notifier_watch_seconds #{doc['notifier_watch_seconds']}, " \
                     "notifier_interval_seconds #{doc['notifier_interval_seconds']}) must be below #{window} s, the CI " \
                     "poll window (10 × github_ci_interval_seconds): a slower watch pass lets gated cards' CI requests lapse"
    end

    def template = YAML.safe_load_file(TEMPLATE)

    # The newest revision: {id, doc, author, at}, or nil.
    def current(db)
      row = db[TABLE].reverse(:id).first
      row && { id: row[:id], doc: JSON.parse(row[:doc]), author: row[:author], at: row[:created_at] }
    end

    def current_id(db) = db[TABLE].max(:id)

    # The current values {scan_interval_seconds: 60, …} — what every reader runs on. Kept per process while the newest
    # id is the same (one MAX(id) per call). No revision → Missing, never a default.
    MEMO = Monitor.new
    def get(db)
      id = current_id(db) or raise Missing, "no runtime settings revision: the table #{TABLE} is empty — " \
                                            "bin/runtime-settings import < config/runtime.template.yml"
      MEMO.synchronize do
        return @memo[1] if @memo && @memo[0] == id

        cur = current(db)
        @memo = [cur[:id], values!(cur[:doc])]
        @memo[1]
      end
    end

    def history(db, limit: 20)
      db[TABLE].reverse(:id).limit(limit).select(:id, :author, :created_at).all
               .map { |r| { id: r[:id], author: r[:author], at: r[:created_at] } }
    end

    def revisions(db) = db[TABLE].count

    # Write a new revision from `doc`, based on revision `base` (the one the editor loaded): validated, `base` still
    # the newest → the new revision's id.
    def save!(db, doc:, base:, author:, clock: -> { Busyyaks::Clock.epoch })
      values!(doc)
      raise Refused, "author is required" if author.to_s.empty?

      db.transaction do
        now = current_id(db)
        raise Conflict, "revision #{base.inspect} is not the newest (#{now.inspect} is): reload, then save again" \
          unless now == base

        db[TABLE].insert(doc: JSON.generate(doc.slice(*KEYS.keys)), author: author.to_s, created_at: clock.call)
      end
    end

    # The old .env lines (KEY=VALUE) → a document: every one of KEYS' .env keys must be there, as a whole number
    # (bin/runtime-settings import-env). Other lines are ignored; a quoted value is unquoted like compose does.
    def from_env_lines(text)
      found = {}
      text.each_line(chomp: true) do |line|
        m = line.match(/\A\s*(?:export\s+)?([A-Z_]+)=(.*)\z/) or next

        key = ENV_KEYS[m[1]] or next
        raw = m[2].strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        found[key] = raw.match?(/\A\d+\z/) ? Integer(raw, 10) : raw
      end
      missing = KEYS.keys - found.keys
      raise Refused, "the .env lines lack #{missing.map { KEYS[_1].first }.join(', ')}" if missing.any?

      found
    end
  end
end
