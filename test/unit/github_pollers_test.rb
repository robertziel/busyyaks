# frozen_string_literal: true

require "test_helper"
require "busyyaks/ci_checks"
require "busyyaks/pr_states"
require "busyyaks/github_pollers"

# The PR pollers (CI checks + PR states) share one token. A rate-limited answer pauses both until GitHub's
# reset: nothing is sent, every wanted row says why and until when, and /github shows the budget and the pause.
class GithubPollersTest < Minitest::Test
  include DBReset

  class FakeHttp
    attr_accessor :requests, :limited, :remaining
    def initialize = (@requests = []; @remaining = 4000)
    def get(url, headers)
      @requests << url
      if @limited
        return [403, @limited.merge("x-ratelimit-limit" => "5000"), "{\"message\":\"API rate limit exceeded for user\"}"]
      end

      body = case url.sub(/\?.*/, "")
             when %r{/pulls/(\d+)\z}
               n = Regexp.last_match(1).to_i
               { "number" => n, "state" => "open", "draft" => false, "html_url" => "https://github.com/o/r/pull/#{n}",
                 "head" => { "sha" => "abc" }, }
             when %r{/status\z} then { "total_count" => 0, "statuses" => [] }
             when %r{/check-runs\z} then { "total_count" => 0, "check_runs" => [] }
             end
      [200, { "x-ratelimit-limit" => "5000", "x-ratelimit-remaining" => @remaining.to_s,
              "x-ratelimit-reset" => "1000900", }, JSON.generate(body),]
    end
  end

  # config ci: jenkins/ci gates on the test repo
  CI = Busyyaks::CiSettings.parse!("max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] })

  def setup
    super
    @db = Hanami.app["db.gateway"].connection
    @now = 1_000_000
    @http = FakeHttp.new
    @gate = Busyyaks::GithubPollers.new(db: @db, clock: -> { @now })
    @db[:gh_pr_checks].insert(repo: "o/r", ref: "pr:5", requested_at: @now)
    @db[:gh_pr_states].insert(repo: "o/r", ref: "pr:1", requested_at: @now)
    @db[:gh_pr_states].insert(repo: "o/r", ref: "pr:2", requested_at: @now)
  end

  # one tick of bin/github's PR thread: a fresh client, both pollers, the gate's record
  def tick
    @client = Busyyaks::GithubNetwork::Client.new(token: "t", http: @http)
    Busyyaks::CiChecks::Poller.new(db: @db, client: @client, gate: @gate, wanted_for: 600, ci: CI, clock: -> { @now }).run
    Busyyaks::PrStates::Poller.new(db: @db, client: @client, gate: @gate, wanted_for: 600, clock: -> { @now }).run
    @gate.finished(@client)
  end

  def errors = @db[:gh_pr_checks].select_map(:error) + @db[:gh_pr_states].order(:id).select_map(:error)
  def want! = %i[gh_pr_checks gh_pr_states].each { |t| @db[t].update(requested_at: @now) }

  def test_rate_limited_pollers_pause_until_reset
    reset = @now + 900
    @http.limited = { "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => reset.to_s }
    tick
    assert_equal ["/repos/o/r/pulls/5"].map { |u| "https://api.github.com#{u}" }, @http.requests,
                 "one rate-limited answer: the rest of the batch and the other poller send nothing"
    until_ = "polling paused until #{Busyyaks::GithubPollers.at(reset)}: GitHub rate limited (0/5000 left"
    errors.each { |e| assert e.start_with?(until_), e }
    assert_nil @db[:gh_pr_states].exclude(checked_at: nil).first, "no old answer stays as the current one"
    row = @gate.status
    assert_equal [reset, 0, 5000, reset], row.values_at(:paused_until, :rate_remaining, :rate_limit, :rate_reset)
    assert_equal 1, row[:calls]

    reader = Busyyaks::PrStates::Reader.new(db: @db, stale_after: 180, wanted_for: 600, clock: -> { @now })
    assert_match(/GitHub read failed: polling paused until /, reader.lookup("o/r", "pr:1")[:error])

    @http.limited = nil
    @now += 600
    want!
    tick
    assert_equal 1, @http.requests.size, "still paused: nothing sent before the reset"
    assert_equal 0, @gate.status[:calls]
    assert_equal 0, @gate.status[:rate_remaining], "a tick that read nothing keeps the last budget read"
    errors.each { |e| assert e.start_with?("polling paused until"), e }
    pollers = Busyyaks::GithubNetwork::Feed.call(Busyyaks::GithubNetwork::Data.new(@db), login: "me", hours: 24,
                                                                                         now: @now)[:pollers]
    assert_equal reset, pollers[:paused_until]
    assert_match(/rate limited/, pollers[:error])

    @now = reset + 1
    want!
    tick
    assert_equal 1 + 5, @http.requests.size, "after the reset: PR + status + check runs, then two PR states"
    assert_equal [nil, nil, nil], errors
    assert_equal %w[open open], @db[:gh_pr_states].order(:id).select_map(:state)
    assert_nil @gate.status[:paused_until]
    assert_nil @gate.paused
    assert_equal [5, 4000], @gate.status.values_at(:calls, :rate_remaining)
  end

  # a secondary limit names its end in Retry-After (x-ratelimit-remaining is not 0)
  def test_a_secondary_limit_pauses_for_its_retry_after
    @http.limited = { "x-ratelimit-remaining" => "3000", "x-ratelimit-reset" => (@now + 3000).to_s, "retry-after" => "120" }
    tick
    assert_equal @now + 120, @gate.status[:paused_until]
    @http.limited = nil
    @now += 121
    want!
    tick
    assert_equal [nil, nil, nil], errors
  end

  # GitHub said "rate limited" and nothing about when it ends: no pause is invented, the next tick asks again
  def test_a_limit_with_no_end_pauses_nothing
    @http.limited = { "x-ratelimit-remaining" => "12" }
    tick
    assert_nil @gate.status[:paused_until]
    errors.each { |e| assert_match(/\AGitHub rate limited \(12\/5000 left, resets unknown\)/, e) }
    assert_equal 2, @http.requests.size, "each poller stops at its first refusal"
    @http.limited = nil
    want!
    tick
    assert_equal [nil, nil, nil], errors
  end

  # the last answer left 0 calls: the next tick sends nothing until the reset that answer named
  def test_a_used_up_limit_pauses_until_its_reset
    @http.remaining = 0
    tick
    assert_equal 1_000_900, @gate.status[:paused_until]
    assert_equal [nil, nil, nil], errors, "this tick's answers are real"
    sent = @http.requests.size
    @now += 60
    want!
    tick
    assert_equal sent, @http.requests.size
    errors.each { |e| assert_match(/\Apolling paused until .*GitHub rate limit used up \(0\/5000 left\)/, e) }
  end

  def test_never_ran_is_nil_on_github
    assert_nil Busyyaks::GithubNetwork::Feed.call(Busyyaks::GithubNetwork::Data.new(@db), login: "me", hours: 24,
                                                                                          now: @now)[:pollers]
  end
end
