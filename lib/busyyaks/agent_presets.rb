# frozen_string_literal: true

require "yaml"

module Busyyaks
  # config/agent_presets.yml: the agent types Settings → Agents & launchers offers as "Add from preset". Read
  # by the settings API (the page's list) and by Skills (busyyaks's own layer accepts an agents/<key>.md for every
  # preset key, added to the settings or not). Pure Ruby, stdlib only: bin/launcher requires it.
  module AgentPresets
    class Invalid < StandardError; end

    FILE = "config/agent_presets.yml" # relative to the checkout
    # the checkout this code runs from (bin/launcher's ROOT, the containers' /app): the presets are the code's own,
    # never a scratch tree's (the writer checks a save on a copy of skills/ only)
    HOME = File.expand_path("../..", __dir__)
    KEY = /\A[a-z][a-z0-9_-]{0,31}\z/
    # what a preset carries: an agent type without `launchers` (the deployment's: the page fills the lead's) + the
    # page's one-line description
    KEYS = %w[key label description model prompt agent_name session_name takes max max_per_project under launchable
              opt_in].freeze

    module_function

    def path(checkout = HOME) = File.join(checkout, FILE)

    # → [preset hash] in file order; a missing file, an unknown or missing key, a duplicate → Invalid (never a guess)
    def load!(checkout = HOME)
      file = path(checkout)
      raw = YAML.safe_load_file(file)
      list = raw.is_a?(Hash) && raw.keys == ["presets"] ? raw["presets"] : nil
      raise Invalid, "#{file}: must be {presets: [agent type, …]}" unless list.is_a?(Array)

      list.each_with_index.map { |p, i| preset!(p, "#{file} presets[#{i}]") }.tap do |ps|
        twice = ps.map { |p| p["key"] }.tally.find { |_, n| n > 1 }
        raise Invalid, "#{file}: preset #{twice.first} is listed twice" if twice
      end
    rescue Psych::Exception, SystemCallError => e
      raise Invalid, "#{file}: #{e.message}"
    end

    def keys(checkout = HOME) = load!(checkout).map { |p| p["key"] }

    def preset!(p, where)
      raise Invalid, "#{where} must be a mapping" unless p.is_a?(Hash)

      unknown = p.keys - KEYS
      missing = KEYS - p.keys
      raise Invalid, "#{where}: unknown keys #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "#{where}: missing keys #{missing.join(', ')}" if missing.any?
      raise Invalid, "#{where}.key must match #{KEY.source}" unless p["key"].is_a?(String) && p["key"].match?(KEY)
      raise Invalid,
"#{where}.description must be one line" unless p["description"].is_a?(String) && !p["description"].include?("\n")

      p
    end

    # The agent type a preset adds (what the page puts in the draft): the preset without its description, running the
    # given launchers
    def type(preset, launchers:) = preset.except("description").merge("launchers" => launchers)
  end
end
