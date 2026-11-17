# frozen_string_literal: true

require "json"
require "openssl"
require_relative "clock"

module Busyyaks
  # GitHub webhooks wake the PR / CI pollers (card #472). POST /api/github/hook takes GitHub's `pull_request`,
  # `status`, `check_run` and `check_suite` deliveries and only marks the matching gh_pr_states / gh_pr_checks rows
  # dirty (`dirty` = a counter); the github service (bin/github) looks for dirty rows every `wake_seconds` and polls just
  # those at once instead of at its next github_ci_interval_seconds tick. Polling stays the source of truth: a payload
  # is never stored nor believed — it only names which rows to read again — and no row is ever created by a hook.
  #
  # What it is lives in config/busyyaks.yml `github_hook` (required): `none` = off (no route: a POST is 404), or
  # {max_body_bytes, wake_seconds}. The secret is env, the web service only: GITHUB_WEBHOOK_SECRET, declared always,
  # empty with `none`, at least MIN_SECRET characters when on — a mismatch stops the web boot (config/puma.rb).
  #
  # The endpoint: behind HostGuard like every route (GitHub sends the public Host and no Origin / Referer); no session
  # nor CSRF token — the HMAC-SHA256 signature (`X-Hub-Signature-256`) over the raw body, compared in constant time, is
  # its only authentication. Refusals, in order: body over max_body_bytes 413 (before reading it) · signature missing or
  # wrong 401 · no event header 400 · not JSON 415 · malformed payload 400. ping → 200; an event it does not take → 204.
  module GithubHook
    class Invalid < StandardError; end

    PATH = "/api/github/hook"
    SECRET = "GITHUB_WEBHOOK_SECRET"
    MIN_SECRET = 32
    KEYS = %w[max_body_bytes wake_seconds].freeze
    CHECK_EVENTS = %w[status check_run check_suite].freeze
    REPO = %r{\A[\w.-]+/[\w.-]+\z}
    SHA = /\A\h{40}\z/
    # GitHub caps a delivery at 25 MB, but the events taken here are far smaller: a pull_request payload carries one PR
    # (its body ≤ 65,536 characters) + the repo and the actors, tens of KB; status / check payloads less. 1 MiB is
    # their ceiling: a bigger one is refused 413 before its signature is computed, and costs only the poll's latency.
    MAX_BODY = 1024 * 1024

    Settings = Struct.new(:max_body_bytes, :wake_seconds, keyword_init: true)

    module_function

    # config/busyyaks.yml `github_hook` → Settings, or nil for `none`
    def parse!(value)
      return nil if value == "none"

      unless value.is_a?(Hash) && value.keys.sort == KEYS.sort
        raise Invalid, "github_hook must be `none` or a mapping with exactly #{KEYS.join(', ')} " \
                       "(config/busyyaks.example.yml)"
      end

      Settings.new(max_body_bytes: int!(value, "max_body_bytes", 1024..MAX_BODY),
                   wake_seconds: int!(value, "wake_seconds", 1..60))
    end

    def int!(value, key, range)
      v = value[key]
      raise Invalid, "github_hook.#{key} must be an integer in #{range}" unless v.is_a?(Integer) && range.cover?(v)

      v
    end

    # The web service's boot check → the secret (nil = off): declared always, set exactly when the hook is on.
    def boot!(settings, env)
      raise Invalid, "#{SECRET} not in the web service's env (.env.example § GitHub webhook)" unless env.key?(SECRET)

      secret = env.fetch(SECRET)
      if settings.nil?
        raise Invalid, "#{SECRET} set but config/busyyaks.yml github_hook is none: empty it or configure the hook" \
          unless secret.empty?

        return nil
      end
      if secret.length < MIN_SECRET || secret.match?(/[\s[:cntrl:]]/)
        raise Invalid, "#{SECRET} must be at least #{MIN_SECRET} characters, no whitespace, when github_hook is on " \
                       "(e.g. `openssl rand -hex 32`)"
      end

      secret
    end

    # GitHub's X-Hub-Signature-256 ("sha256=<hex>") of body under secret, in constant time
    def signed?(secret, body, header)
      return false unless header.is_a?(String) && header.start_with?("sha256=")

      OpenSSL.secure_compare(header, "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}")
    end

    # Marks the rows `event` names dirty → how many. Only rows the web or the notifier asked for within wanted_for (the
    # pollers' window) — an unwanted row would not be polled anyway. Raises Invalid on a payload missing what it needs.
    def mark(db, event, payload, now:, wanted_for:)
      repo = payload.dig("repository", "full_name")
      raise Invalid, "repository.full_name is not owner/name" unless repo.is_a?(String) && repo.match?(REPO)

      wanted = ->(t) { db[t].where(Sequel.function(:lower, :repo) => repo.downcase).where { requested_at >= now - wanted_for } }
      if event == "pull_request"
        n = payload["number"]
        raise Invalid, "number is not a PR number" unless n.is_a?(Integer) && n.positive?

        # a final answer (merged, read without error) is never polled again (PrStates::Poller): marking it would keep
        # the waker waking for a row no pass clears
        final = Sequel.&({ state: PrStates::FINAL }, { error: nil }, Sequel.~(checked_at: nil))
        return bump(wanted.call(:gh_pr_states).where(ref: "pr:#{n}").exclude(final)) +
               bump(wanted.call(:gh_pr_checks).where(ref: ["pr:#{n}", "merge:#{n}"]))
      end

      sha, numbers = check_target(event, payload)
      # a pr: row whose head is that commit, a PR the check names, and every merge: row of the repo (its sha — the merge
      # commit or the base head that contains it — is not kept; a conditional read of an unchanged one costs nothing)
      refs = numbers.map { |x| "pr:#{x}" }
      bump(wanted.call(:gh_pr_checks).where(Sequel.|({ head: sha }, { ref: refs }, Sequel.like(:ref, "merge:%"))))
    end

    # status / check_run / check_suite → [the commit sha, the PR numbers the payload names]
    def check_target(event, payload)
      obj = event == "status" ? payload : payload[event]
      raise Invalid, "#{event} payload has no #{event} object" unless obj.is_a?(Hash)

      sha = event == "status" ? obj["sha"] : obj["head_sha"]
      raise Invalid, "#{event} payload has no commit sha" unless sha.is_a?(String) && sha.match?(SHA)

      prs = obj["pull_requests"]
      numbers = prs.is_a?(Array) ? prs.filter_map { |p| p["number"] if p.is_a?(Hash) && p["number"].is_a?(Integer) } : []
      [sha, numbers]
    end

    def bump(dataset) = dataset.update(dirty: Sequel.function(:coalesce, :dirty, 0) + 1)

    # A poller read the row: its dirty mark is cleared unless a hook marked it again since it was selected.
    def clean(dataset, row)
      dataset.where(id: row[:id], dirty: row[:dirty]).update(dirty: nil) if row[:dirty]
    end

    # The github service's wait between two full polls: `interval` seconds, but every `wake_seconds` a wanted dirty row
    # runs the block (the pollers' dirty-only pass) at once. nil settings (hook off) = one plain sleep.
    class Waker
      def initialize(db:, settings:, wanted_for:, sleeper: ->(s) { Busyyaks::Clock.pause(s) },
                     clock: -> { Busyyaks::Clock.monotonic }, now: -> { Busyyaks::Clock.epoch })
        @db = db
        @settings = settings
        @wanted_for = wanted_for
        @sleeper = sleeper
        @clock = clock
        @now = now
      end

      def wait(interval)
        return @sleeper.call(interval) unless @settings

        deadline = @clock.call + interval
        while (left = deadline - @clock.call).positive?
          @sleeper.call([@settings.wake_seconds, left].min)
          yield if dirty?
        end
      end

      def dirty?
        since = @now.call - @wanted_for
        %i[gh_pr_states gh_pr_checks].any? { |t| !@db[t].exclude(dirty: nil).where { requested_at >= since }.empty? }
      end
    end

    # POST /api/github/hook (mounted by config/routes.rb only when the hook is on). wanted_for: -> seconds, asked per
    # delivery (the CI poll window of Settings → Runtime's github_ci_interval_seconds, card #523).
    class Endpoint
      def initialize(secret:, settings:, wanted_for:, db: -> { Hanami.app["db.gateway"].connection },
                     clock: -> { Busyyaks::Clock.epoch })
        raise Invalid, "the webhook secret is empty" if secret.to_s.empty?

        @secret = secret
        @settings = settings
        @wanted_for = wanted_for
        @db = db
        @clock = clock
      end

      def call(env)
        max = @settings.max_body_bytes
        return answer(413, error: "payload over #{max} bytes") if env["CONTENT_LENGTH"].to_i > max

        # Rack 3: a request with no body may carry no rack.input — an empty body, refused by the signature check
        body = (env["rack.input"]&.read(max + 1)).to_s
        return answer(413, error: "payload over #{max} bytes") if body.bytesize > max
        return answer(401, error: "signature missing or wrong") \
          unless GithubHook.signed?(@secret, body, env["HTTP_X_HUB_SIGNATURE_256"])

        event = env["HTTP_X_GITHUB_EVENT"].to_s
        return answer(400, error: "no X-GitHub-Event header") if event.empty?
        return answer(200, ok: "pong") if event == "ping"
        return [204, {}, []] unless event == "pull_request" || CHECK_EVENTS.include?(event)
        unless env["CONTENT_TYPE"].to_s.split(";").first&.strip == "application/json"
          return answer(415, error: "the webhook's content type must be application/json")
        end

        payload = JSON.parse(body)
        return answer(400, error: "payload is not a JSON object") unless payload.is_a?(Hash)

        answer(200, event: event,
                    marked: GithubHook.mark(@db.call, event, payload, now: @clock.call, wanted_for: @wanted_for.call))
      rescue JSON::ParserError
        answer(400, error: "payload is not JSON")
      rescue Invalid => e
        answer(400, error: e.message)
      end

      private

      def answer(status, **body)
        [status, { "content-type" => "application/json", "cache-control" => "no-store" }, [JSON.dump(body)]]
      end
    end
  end
end
