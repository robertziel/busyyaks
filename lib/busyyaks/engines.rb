# frozen_string_literal: true

require "yaml"
require_relative "agent_screen"

module Busyyaks
  # The coding-agent engines: the names the agent_engines collector reports per pane. What an engine IS is
  # configuration — config/engines.yml (committed: `claude` + the collector's names) with a deployment's own
  # `engines:` from config/busyyaks.yml merged over it (new names, or relabels); how a family BEHAVES is code, one
  # class per family: which screen rules read it, whether a busyyaks message may be typed into it. A name the
  # collector reports that is in neither → Unknown (shown as the pane's screen error), never a guessed family.
  # Pure Ruby, no dependencies: bin/launcher (host) requires this file alone.
  module Engines
    class Invalid < StandardError; end

    class Family
      def name = raise(NotImplementedError)
      def rules = raise(NotImplementedError)
      # may a busyyaks message be typed into the pane mid-turn (bin/launcher notify)?
      def typeable? = false
    end

    # Claude Code queues a prompt typed mid-turn.
    class ClaudeCode < Family
      def name = "claude"
      def rules = AgentScreen::CLAUDE
      def typeable? = true
    end

    # Hermes' input state is unreadable, so typing into it is not risked.
    class Hermes < Family
      def name = "hermes"
      def rules = AgentScreen::HERMES
    end

    FAMILIES = [ClaudeCode, Hermes].map(&:new).to_h { |f| [f.name, f] }.freeze
    DEFAULTS_PATH = File.expand_path("../../config/engines.yml", __dir__)
    NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

    Engine = Struct.new(:name, :label, :family, keyword_init: true)

    class Unknown < StandardError; end

    # overrides: the `engines:` mapping of config/busyyaks.yml (nil = the key is absent → config/engines.yml alone).
    def self.load(overrides, defaults_path: DEFAULTS_PATH)
      raise Invalid, "engine defaults not found: #{defaults_path}" unless File.file?(defaults_path)

      defaults = YAML.safe_load_file(defaults_path)
      raise Invalid, "#{defaults_path} must be a non-empty mapping" unless defaults.is_a?(Hash) && defaults.any?
      unless overrides.nil? || overrides.is_a?(Hash)
        raise Invalid, "engines must be a mapping of engine name → {label, family}"
      end

      parse(defaults.merge(overrides || {}))
    end

    def self.parse(value)
      raise Invalid, "engines must be a mapping of engine name → {label, family}" unless value.is_a?(Hash)

      table = value.to_h do |name, e|
        raise Invalid, "engine name #{name.inspect} must match #{NAME.source}" unless name.is_a?(String) && name.match?(NAME)
        unless e.is_a?(Hash) && e.keys.sort == %w[family label]
          raise Invalid, "engine #{name}: must be a mapping with exactly label and family"
        end
        unless e["label"].is_a?(String) && !e["label"].strip.empty?
          raise Invalid, "engine #{name}: label must be a non-empty string"
        end

        family = FAMILIES[e["family"]] or
          raise Invalid, "engine #{name}: unknown family #{e['family'].inspect} (known: #{FAMILIES.keys.join(', ')})"
        [name, Engine.new(name: name, label: e["label"], family: family)]
      end
      Table.new(table)
    end

    class Table
      def initialize(engines) = @engines = engines.freeze
      def names = @engines.keys

      def fetch(name) = @engines.fetch(name.to_s) { raise Unknown, missing(name) }
      def missing(name)
        "engine #{name.to_s.inspect} is not configured (config/busyyaks.yml engines; known: #{names.join(', ')})"
      end

      def known?(name) = @engines.key?(name.to_s)

      # bin/launcher's pane: {label, family} for a known engine, {error} for one that is not configured
      def pane(name) = known?(name) ? { label: fetch(name).label, family: fetch(name).family } : { error: missing(name) }

      # bin/launcher notify: the engines among `names` a message may not be typed into → [[name, why]]
      def untypeable(names)
        names.uniq.filter_map do |n|
          next [n, "not configured"] unless known?(n)

          [n, "family #{fetch(n).family.name}"] unless fetch(n).family.typeable?
        end
      end
    end
  end
end
