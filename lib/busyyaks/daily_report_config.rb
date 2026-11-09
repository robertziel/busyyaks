# frozen_string_literal: true

module Busyyaks
  # `daily_report:` in config/busyyaks.yml: how the daily report runs on this deployment — when it ticks,
  # which OpenAI-compatible gateway and models it uses, and the RUNNER (the agent CLI that writes it). Absent key =
  # this deployment has no daily report (bin/daily-report and deploy/install-daily-timer.sh refuse, naming the key).
  # Every key inside is required, unknown keys refused, no defaults. The host script reads the validated values
  # through the MCP tool `daily_report_config` — this class is the only parser.
  #
  # A runner type is a family of behaviour: its keys are checked here, its script is bin/daily-report-runners/<type>
  # (the prompt, the CLI's own config, how it is invoked). A new runner = a new entry in RUNNERS + a new script.
  class DailyReportConfig
    class Invalid < StandardError; end

    KEYS = %w[schedule cutoff probe_timeout run_timeout gateway model agent_model context_length runner].freeze
    RUNNERS = {
      # Hermes (NousResearch hermes-agent): `command` on the host PATH, its own HERMES_HOME (config generated per run),
      # max_children = delegate_task children at once (one per active repo).
      "hermes" => %w[command home max_children],
    }.freeze
    CUTOFF = /\A([01]\d|2[0-3]):[0-5]\d\z/
    DURATION = /\A\d+[smhd]?\z/ # timeout(1)

    attr_reader :values

    def self.parse(value) = value.nil? ? nil : new(value)

    def initialize(h)
      raise Invalid, "daily_report must be a mapping" unless h.is_a?(Hash)

      check_keys("daily_report", h, KEYS)
      @values = {
        schedule: str(h, "schedule"),
        cutoff: match(h, "cutoff", CUTOFF, "HH:MM"),
        probe_timeout: pos_int(h, "probe_timeout"),
        run_timeout: match(h, "run_timeout", DURATION, "a timeout(1) duration like 90m"),
        gateway: url(h, "gateway"),
        model: str(h, "model"),
        agent_model: str(h, "agent_model"),
        context_length: pos_int(h, "context_length"),
        runner: runner(h["runner"]),
      }
    end

    def to_h = @values

    private

    def runner(r)
      raise Invalid, "daily_report.runner must be a mapping with a type" unless r.is_a?(Hash) && r.key?("type")

      keys = RUNNERS[r["type"]] or
        raise Invalid, "daily_report.runner.type #{r['type'].inspect} is not a runner (known: #{RUNNERS.keys.join(', ')})"
      check_keys("daily_report.runner", r, ["type", *keys])
      out = { type: r["type"] }
      keys.each do |k|
        out[k.to_sym] = k == "max_children" ? pos_int(r, k, "daily_report.runner") : str(r, k, "daily_report.runner")
      end
      out
    end

    def check_keys(where, h, keys)
      unknown = h.keys - keys
      missing = keys - h.keys
      raise Invalid, "#{where}: unknown keys: #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "#{where}: missing keys: #{missing.join(', ')}" if missing.any?
    end

    def str(h, k, where = "daily_report")
      v = h[k]
      raise Invalid, "#{where}.#{k} must be a non-empty string" unless v.is_a?(String) && !v.strip.empty?
      # values reach the host script's environment one per line: a newline / control char would split one into two
      raise Invalid, "#{where}.#{k} must not contain control characters" if v.match?(/[[:cntrl:]]/)

      v
    end

    def pos_int(h, k, where = "daily_report")
      v = h[k]
      raise Invalid, "#{where}.#{k} must be a positive integer" unless v.is_a?(Integer) && v.positive?

      v
    end

    def match(h, k, re, what)
      v = h[k].to_s
      raise Invalid, "daily_report.#{k} must be #{what}, got #{h[k].inspect}" unless h[k].is_a?(String) && v.match?(re)

      v
    end

    def url(h, k)
      v = str(h, k)
      unless v.match?(%r{\Ahttps?://\S+\z})
        raise Invalid, "daily_report.#{k} must be an http(s) URL (the OpenAI-compatible base, ends in /v1)"
      end

      v.chomp("/")
    end
  end
end
