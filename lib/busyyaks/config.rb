# frozen_string_literal: true

require "yaml"
require_relative "engines"
require_relative "agent_collector"
require_relative "daily_report_config"
require_relative "owner_remotes"
require_relative "launch_trust"

module Busyyaks
  # The deployment's YAML (config/busyyaks.yml). Every key required, unknown keys refused,
  # no defaults: a missing value fails at boot, not as a quietly empty dashboard.
  class Config
    class Invalid < StandardError; end

    KEYS = %w[roots search_depth owner_remotes author_emails window_days reap_protect auth agents launch].freeze
    OPTIONAL = %w[engines daily_report].freeze
    attr_reader :roots, :search_depth, :owner_remotes, :author_emails, :window_days, :reap_protect, :engines, :daily_report,
                :auth, :agent_collector, :trusted_paths

    # mount: where compose mounts PROJECTS_ROOT (.env PROJECTS_MOUNT, the one place it is set): every root is under it.
    def self.load(path = ENV.fetch("BUSYYAKS_CONFIG"), mount: ENV.fetch("PROJECTS_MOUNT"))
      raise Invalid, "config file not found: #{path}" unless File.file?(path)

      new(YAML.safe_load_file(path)).tap do |c|
        c.roots_under!(mount)
        LaunchTrust.under_mount!(c.trusted_paths, mount)
      rescue LaunchTrust::Invalid => e
        raise Invalid, e.message
      end
    end

    def roots_under!(mount)
      outside = roots.map { |r| r[:path] }.reject { |p| p == mount || p.start_with?("#{mount.chomp('/')}/") }
      return if outside.empty?

      raise Invalid, "roots #{outside.join(', ')} not under PROJECTS_MOUNT #{mount} (where compose mounts PROJECTS_ROOT)"
    end

    def initialize(hash)
      raise Invalid, "config must be a mapping" unless hash.is_a?(Hash)

      unknown = hash.keys - KEYS - OPTIONAL
      missing = KEYS - hash.keys
      raise Invalid, "unknown keys: #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "missing keys: #{missing.join(', ')}" if missing.any?

      @roots = parse_roots(hash["roots"])
      # launch.trusted_paths: whose folder-trust prompt bin/launcher answers (LaunchTrust; [] = none)
      @trusted_paths = begin
        LaunchTrust.parse!(hash["launch"])
      rescue LaunchTrust::Invalid => e
        raise Invalid, e.message
      end
      @search_depth = hash["search_depth"]
      raise Invalid, "search_depth must be an integer >= 0" unless @search_depth.is_a?(Integer) && @search_depth >= 0
      @owner_remotes = parse_owner_remotes(hash["owner_remotes"])
      @author_emails = list(hash, "author_emails").map(&:downcase)
      @window_days = hash["window_days"]
      raise Invalid, "window_days must be a positive integer" unless @window_days.is_a?(Integer) && @window_days.positive?
      @reap_protect = hash["reap_protect"]
      unless @reap_protect.is_a?(Array) && @reap_protect.all? { |x| x.is_a?(String) && !x.empty? }
        raise Invalid, "reap_protect must be a list of tmux session name patterns (globs; [] for none)"
      end
      # sign-in: {provider: none} or {provider: <dir>, …its settings}; Busyyaks::Auth.build validates the rest
      @auth = hash["auth"]
      unless @auth.is_a?(Hash) && @auth["provider"].is_a?(String) && !@auth["provider"].empty?
        raise Invalid, "auth must be a mapping with a provider key: none, or a provider directory (README \"Sign-in\")"
      end
      begin
        @agent_collector = AgentCollector.parse(hash["agents"]) # nil = collector: none (bin/launcher checks the paths)
      rescue AgentCollector::Invalid => e
        raise Invalid, e.message
      end
      begin
        @engines = Engines.load(hash["engines"])
      rescue Engines::Invalid => e
        raise Invalid, e.message
      end
      begin
        @daily_report = DailyReportConfig.parse(hash["daily_report"]) # nil = this deployment has no daily report
      rescue DailyReportConfig::Invalid => e
        raise Invalid, e.message
      end
    end

    private

    # roots: [{path:, prefix:}] — prefix namespaces the slugs of a nested root ("acme/" → acme/x),
    # so two repos with the same directory name in different roots never collide. Both keys required.
    def parse_roots(value)
      unless value.is_a?(Array) && value.any?
        raise Invalid, "roots must be a non-empty list of {path, prefix}"
      end

      value.map do |r|
        unless r.is_a?(Hash) && r.keys.sort == %w[path prefix]
          raise Invalid, "each root must be a mapping with exactly path and prefix"
        end
        raise Invalid, "root path must be a non-empty string" unless r["path"].is_a?(String) && !r["path"].empty?
        raise Invalid, "root prefix must be a string (may be empty)" unless r["prefix"].is_a?(String)

        { path: r["path"], prefix: r["prefix"] }
      end.tap do |rs|
        dup = rs.group_by { |r| r[:prefix] }.select { |_, v| v.size > 1 }.keys
        raise Invalid, "two roots share prefix #{dup.first.inspect}" if dup.any?
      end
    end

    # the one OwnerRemotes rule (the scanner's `own` flag)
    def parse_owner_remotes(value)
      OwnerRemotes.validate!(value)
    rescue OwnerRemotes::Invalid => e
      raise Invalid, e.message
    end

    def list(hash, key)
      value = hash[key]
      unless value.is_a?(Array) && value.any? && value.all? { |v| v.is_a?(String) && !v.empty? }
        raise Invalid, "#{key} must be a non-empty list of strings"
      end

      value
    end
  end
end
