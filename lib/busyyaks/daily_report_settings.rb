# frozen_string_literal: true

require "json"
require_relative "daily_report_config"

module Busyyaks
  # The daily report settings: what config/busyyaks.yml `daily_report` held — schedule, cutoff, timeouts,
  # gateway, models, runner — kept in the DATABASE as revisions (table daily_report_settings: the newest row is the
  # current one, every earlier one stays as history), edited on Settings → Daily report. No revision = this deployment
  # has no daily report configured: bin/daily-report posts ONE visible "NOT CONFIGURED" report a day (never a
  # journal-only exit). DailyReportConfig is the one validator of a revision.
  #
  # The guard: the runner runs ON THE HOST (bin/daily-report → bin/daily-report-runners/<type>), and a revision is
  # written by whoever holds a dashboard session. So the host keeps what a runner may execute and where it may write —
  # config/busyyaks.yml `daily_report_runners`, a host file (mounted read-only into the containers): each entry is a
  # runner type with exactly its HOST_KEYS (hermes: command, home), and a revision's runner must equal one of them on
  # those keys. A dashboard session picks among those; what stays editable (the gateway, the models, the schedule, the
  # limits, max_children) is what the runner is told and when, never what the host executes.
  module DailyReportSettings
    TABLE = :daily_report_settings
    # per runner type: the keys of DailyReportConfig::RUNNERS[type] that only the host allowlist sets
    HOST_KEYS = { "hermes" => %w[command home] }.freeze

    class Error < StandardError; end
    # a save based on a revision that is no longer the newest (someone saved in between): reload, then save again
    class Conflict < Error; end
    # the revision is refused: DailyReportConfig's validation, or a runner not on the host allowlist
    class Refused < Error; end

    module_function

    # config/busyyaks.yml `daily_report_runners` (optional; absent = none: every save is refused, naming the key):
    # [{type, <HOST_KEYS[type]>}], each value a non-empty string without control characters. Unique.
    def runners!(value)
      return [].freeze if value.nil?
      raise Error, "daily_report_runners must be a list of {type, #{HOST_KEYS.map { |t, k|
 "#{t}: #{k.join(', ')}" }.join('; ')}}" \
        unless value.is_a?(Array)

      list = value.map.with_index { |v, i| runner_entry!(v, "daily_report_runners[#{i}]") }
      twice = list.tally.find { |_, n| n > 1 }
      raise Error, "daily_report_runners: duplicate entry #{twice.first.inspect}" if twice

      list.freeze
    end

    def runner_entry!(v, where)
      raise Error, "#{where} must be a mapping with a type" unless v.is_a?(Hash) && v["type"].is_a?(String)

      keys = HOST_KEYS[v["type"]] or
        raise Error, "#{where}.type #{v['type'].inspect} is not a runner (known: #{HOST_KEYS.keys.join(', ')})"
      raise Error, "#{where} must have exactly type, #{keys.join(', ')}" unless v.keys.sort == ["type", *keys].sort

      keys.each do |k|
        s = v[k]
        raise Error, "#{where}.#{k} must be a non-empty string" unless s.is_a?(String) && !s.strip.empty?
        raise Error, "#{where}.#{k} must not contain control characters" if s.match?(/[[:cntrl:]]/)
      end
      v.slice("type", *keys).freeze
    end

    # the host part of a validated runner ({type:, command:, …} symbols) as an allowlist entry
    def host_part(runner) = { "type" => runner[:type] }.merge(HOST_KEYS.fetch(runner[:type]).to_h { [_1, runner[_1.to_sym]] })

    # A revision's document validated: DailyReportConfig (every key, no defaults) + its runner on `runners`.
    def config!(doc, runners)
      raise Refused, "daily report settings must be an object {#{DailyReportConfig::KEYS.join(', ')}}" unless doc.is_a?(Hash)

      cfg = DailyReportConfig.new(doc)
      part = host_part(cfg.to_h[:runner])
      return cfg if runners.include?(part)

      allowed = runners.empty? ? "none: config/busyyaks.yml has no daily_report_runners" : runners.map(&:inspect).join("; ")
      raise Refused, "runner #{part.inspect} is not on this host's allowlist config/busyyaks.yml daily_report_runners " \
                     "(#{allowed})"
    rescue DailyReportConfig::Invalid => e
      raise Refused, e.message
    end

    # The newest revision: {id, doc, author, at}, or nil (never configured).
    def current(db)
      row = db[TABLE].reverse(:id).first
      row && { id: row[:id], doc: JSON.parse(row[:doc]), author: row[:author], at: row[:created_at] }
    end

    def current_id(db) = db[TABLE].max(:id)

    # every revision kept (history lists only the newest `limit`)
    def revisions(db) = db[TABLE].count

    def history(db, limit: 20)
      db[TABLE].reverse(:id).limit(limit).select(:id, :author, :created_at).all
               .map { |r| { id: r[:id], author: r[:author], at: r[:created_at] } }
    end

    # What the host script runs on: the current revision validated against `runners`.
    #   → [:ok, DailyReportConfig] · [:not_configured, why] (no revision, or the current one no longer validates —
    #     a runner the host allowlist dropped since it was saved): never a guess, never an older revision.
    def resolve(db, runners)
      cur = current(db)
      return [:not_configured, "no daily report settings saved: Settings → Daily report"] if cur.nil?

      [:ok, config!(cur[:doc], runners)]
    rescue Refused => e
      [:not_configured, "revision #{cur[:id]} does not run: #{e.message}"]
    end

    # Write a new revision from `doc`, based on revision `base` (the one the editor loaded; nil = none existed):
    # validated, the runner on `runners`, `base` still the newest → the new revision's id.
    def save!(db, doc:, base:, author:, runners:, clock: -> { Time.now.to_i })
      config!(doc, runners)
      raise Refused, "author is required" if author.to_s.empty?

      db.transaction do
        now = current_id(db)
        raise Conflict,
"revision #{base.inspect} is not the newest (#{now.inspect} is): reload, then save again" unless now == base

        db[TABLE].insert(doc: JSON.generate(doc), author: author.to_s, created_at: clock.call)
      end
    end
  end
end
