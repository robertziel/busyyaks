# frozen_string_literal: true

require_relative "clock"

module Busyyaks
  # The github service's PR pollers (CiChecks::Poller + PrStates::Poller) share one token and one loop (bin/github). When
  # GitHub says the token's limit is used up, retrying every row every tick only spends the next window's budget the
  # moment it opens; so a RateLimited answer pauses BOTH pollers until GitHub's end of it (Retry-After, else
  # x-ratelimit-reset) and, while paused, they send nothing and every wanted row says why and until when (never its
  # old answer as the current one). A tick that leaves 0 calls left pauses the same way. A RateLimited answer that names
  # no end pauses nothing: the next tick asks again (nothing is guessed).
  #
  # One gh_pollers row (name NAME): the last tick's cost, the rate limit after it, the pause. /github shows it.
  class GithubPollers
    NAME = "pr_pollers"

    def initialize(db:, clock: -> { Busyyaks::Clock.epoch })
      @db = db
      @clock = clock
    end

    # nil, or why nothing is polled now
    def paused
      row = status
      return nil unless row && row[:paused_until] && row[:paused_until] > @clock.call

      "polling paused until #{self.class.at(row[:paused_until])}: #{row[:error]}"
    end

    # A RateLimited answer → the text the row and every row after it in the batch store; paused when GitHub said until when.
    def rate_limited!(error)
      now = @clock.call
      ends = error.retry_after ? now + error.retry_after : error.reset
      return error.message unless ends && ends > now

      save(paused_until: ends, error: error.message[0, 500])
      paused
    end

    # End of a tick: its cost and the limit left (the client's last answer). A pause still running is kept; a used-up
    # limit read this tick starts one; otherwise none.
    def finished(client, calls: client.calls, not_modified: client.not_modified)
      now = @clock.call
      r = client.rate
      attrs = { ran_at: now, calls: calls, not_modified: not_modified }
      # a tick that sent nothing read no limit: the last one read stays (with its own reset time), never blanked
      attrs.merge!(rate_limit: r[:limit], rate_remaining: r[:remaining], rate_reset: r[:reset]) unless r.empty?
      row = status
      unless row && row[:paused_until] && row[:paused_until] > now
        used_up = r[:remaining]&.zero? && r[:reset].to_i > now
        attrs[:paused_until] = used_up ? r[:reset] : nil
        attrs[:error] = used_up ? "GitHub rate limit used up (0/#{r[:limit]} left)" : nil
      end
      save(attrs)
    end

    def status = @db[:gh_pollers].where(name: NAME).first

    def self.at(epoch) = Time.at(epoch).strftime("%Y-%m-%d %H:%M:%S %Z")

    private

    def save(attrs)
      return if @db[:gh_pollers].where(name: NAME).update(attrs).positive?

      @db[:gh_pollers].insert({ name: NAME, ran_at: @clock.call, calls: 0, not_modified: 0 }.merge(attrs))
    end
  end
end
