# frozen_string_literal: true

module Busyyaks
  # config/busyyaks.yml `ci` (card #470): how the github service reads a PR's CI (CiChecks::Poller). Both keys required,
  # no default:
  #   max_pending_minutes: 1..1440 — a REQUIRED check pending longer than this (since GitHub says it started) is `stuck`:
  #                        the gate says so and the owner is pinged, instead of "CI is still running" forever.
  #   required:            {"owner/name" => [context, …]} — per repo, the status contexts / check-run names that gate
  #                        (e.g. jenkins/ci). Every other check on the commit is informational: read and named, never
  #                        a refusal. A repo not listed is never guessed: its rows answer "no required CI contexts".
  module CiSettings
    class Invalid < StandardError; end

    KEYS = %w[max_pending_minutes required].freeze
    REPO = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

    Settings = Struct.new(:max_pending_minutes, :required, keyword_init: true) do
      def max_pending_seconds = max_pending_minutes * 60

      # → the required contexts of repo (owner/name, case-insensitive, as GitHub treats it) | nil when not listed
      def required_for(repo) = required[repo.to_s.downcase]
    end

    module_function

    def parse!(value)
      unless value.is_a?(Hash) && value.keys.sort == KEYS
        raise Invalid, "ci must be a mapping with exactly #{KEYS.join(', ')} (config/busyyaks.example.yml)"
      end

      max = value["max_pending_minutes"]
      unless max.is_a?(Integer) && max.between?(1, 1440)
        raise Invalid, "ci.max_pending_minutes must be an integer 1..1440 (got #{max.inspect})"
      end

      Settings.new(max_pending_minutes: max, required: required!(value["required"]))
    end

    def required!(value)
      unless value.is_a?(Hash) && value.any?
        raise Invalid, "ci.required must be a non-empty mapping of owner/name → [contexts that gate]"
      end

      value.each_with_object({}) do |(repo, contexts), out|
        raise Invalid, "ci.required: #{repo.inspect} is not owner/name" unless repo.is_a?(String) && repo.match?(REPO)
        unless contexts.is_a?(Array) && contexts.any? && contexts.all? { |c| c.is_a?(String) && !c.strip.empty? }
          raise Invalid, "ci.required.#{repo} must be a non-empty list of status contexts / check-run names"
        end
        raise Invalid, "ci.required.#{repo} lists a context twice" if contexts.uniq.size != contexts.size

        key = repo.downcase
        raise Invalid, "ci.required lists #{repo} twice (repo names are case-insensitive)" if out.key?(key)

        out[key] = contexts.freeze
      end.freeze
    end
  end
end
