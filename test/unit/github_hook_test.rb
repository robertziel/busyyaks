# frozen_string_literal: true

require "test_helper"
require "stringio"
require "busyyaks/github_hook"
require "busyyaks/host_guard"
require "busyyaks/ci_checks"
require "busyyaks/pr_states"
require "busyyaks/github_pollers"
require "busyyaks/ci_settings"

# GitHub webhooks wake the PR / CI pollers (card #472): the endpoint's refusals, the rows a delivery marks dirty, the
# pollers' dirty-only pass and the github service's wait — and that the hook is off unless configured with a secret.
class GithubHookTest < Minitest::Test
  include DBReset
  H = Busyyaks::GithubHook
  SECRET = "s" * 40
  SHA = "a" * 40
  SETTINGS = H::Settings.new(max_body_bytes: 4096, wake_seconds: 5)

  def setup
    super
    @db = Hanami.app["db.gateway"].connection
    @now = 1_000_000
    @hook = H::Endpoint.new(secret: SECRET, settings: SETTINGS, wanted_for: -> { 600 }, db: -> { @db }, clock: -> { @now })
  end

  def sign(body, secret = SECRET) = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"

  def deliver(event, payload, signature: :good, type: "application/json", app: @hook, extra: {})
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => H::PATH, "CONTENT_TYPE" => type,
            "CONTENT_LENGTH" => body.bytesize.to_s, "rack.input" => StringIO.new(body), "HTTP_HOST" => "busy.example.com", }
    env["HTTP_X_GITHUB_EVENT"] = event if event
    env["HTTP_X_HUB_SIGNATURE_256"] = signature == :good ? sign(body) : signature if signature
    status, _h, out = app.call(env.merge(extra))
    [status, out.join.empty? ? nil : JSON.parse(out.join)]
  end

  def row(table, repo, ref, requested_at: @now, head: nil)
    attrs = { repo: repo, ref: ref, requested_at: requested_at }
    attrs[:head] = head if head
    @db[table].insert(attrs)
  end

  def dirty(table, id) = @db[table].where(id: id).get(:dirty)

  def pr_event(n, repo = "Own/Repo") = { "action" => "synchronize", "number" => n, "repository" => { "full_name" => repo } }

  def test_webhook_marks_rows_dirty_and_rejects_bad_signatures
    st = row(:gh_pr_states, "own/repo", "pr:5")
    pr = row(:gh_pr_checks, "own/repo", "pr:5")
    merge = row(:gh_pr_checks, "own/repo", "merge:5")
    other_pr = row(:gh_pr_states, "own/repo", "pr:6")
    other_repo = row(:gh_pr_states, "own/other", "pr:5")
    unwanted = row(:gh_pr_states, "own/repo", "pr:7", requested_at: @now - 601)
    old = row(:gh_pr_checks, "own/repo", "pr:7", requested_at: @now - 601)

    # every refusal marks nothing
    assert_equal 401, deliver("pull_request", pr_event(5), signature: nil).first
    assert_equal 401, deliver("pull_request", pr_event(5), signature: sign("x")).first
    assert_equal 401, deliver("pull_request", pr_event(5), signature: sign(JSON.generate(pr_event(5)), "t" * 40)).first
    assert_equal 401, deliver("pull_request", pr_event(5), signature: "sha1=#{'0' * 40}").first
    assert_nil dirty(:gh_pr_states, st)

    # the repo matched in any case (GitHub's full_name vs the stored remote slug); only that PR's rows, only wanted ones
    assert_equal [200, { "event" => "pull_request", "marked" => 3 }], deliver("pull_request", pr_event(5))
    assert_equal [1, 1, 1], [dirty(:gh_pr_states, st), dirty(:gh_pr_checks, pr), dirty(:gh_pr_checks, merge)]
    assert_nil dirty(:gh_pr_states, other_pr)
    assert_nil dirty(:gh_pr_states, other_repo)
    assert_equal 0, deliver("pull_request", pr_event(7)).last["marked"], "rows nobody asked for within the window"
    assert_nil dirty(:gh_pr_states, unwanted)
    assert_nil dirty(:gh_pr_checks, old)
    deliver("pull_request", pr_event(5))
    assert_equal 2, dirty(:gh_pr_states, st), "a counter: a poll clears only the mark it read"
    assert_equal 0, @db[:gh_pr_states].exclude(state: nil).count, "a delivery never writes a state"
  end

  # a merged PR's answer is final: no pass polls it again, so a mark on it would wake the waker every wake_seconds
  # for nothing — it is never marked. One read with an error, or not read yet, is polled: marked.
  def test_a_final_pr_state_is_not_marked
    merged = row(:gh_pr_states, "o/r", "pr:1")
    @db[:gh_pr_states].where(id: merged).update(state: "merged", checked_at: @now)
    failed = row(:gh_pr_states, "o/r", "pr:2")
    @db[:gh_pr_states].where(id: failed).update(state: "merged", error: "GitHub 502")
    unread = row(:gh_pr_states, "o/r", "pr:3")
    @db[:gh_pr_states].where(id: unread).update(state: "merged")
    closed = row(:gh_pr_states, "o/r", "pr:4")
    @db[:gh_pr_states].where(id: closed).update(state: "closed", checked_at: @now)
    (1..4).each { |n| deliver("pull_request", pr_event(n, "o/r")) }
    assert_equal [nil, 1, 1, 1], [merged, failed, unread, closed].map { |id| dirty(:gh_pr_states, id) }
    waker = H::Waker.new(db: @db, settings: SETTINGS, wanted_for: 600, now: -> { @now })
    @db[:gh_pr_states].exclude(id: merged).update(dirty: nil)
    refute waker.dirty?, "nothing for a pass to read: no wake"
  end

  def test_status_and_check_events_mark_the_heads_rows_the_prs_named_and_the_merge_rows
    head = row(:gh_pr_checks, "o/r", "pr:1", head: SHA)
    named = row(:gh_pr_checks, "o/r", "pr:2", head: "b" * 40)
    merge = row(:gh_pr_checks, "o/r", "merge:3")
    other = row(:gh_pr_checks, "o/r", "pr:4", head: "c" * 40)
    state = row(:gh_pr_states, "o/r", "pr:1")
    repo = { "full_name" => "o/r" }
    assert_equal 2, deliver("status", { "sha" => SHA, "state" => "success", "repository" => repo }).last["marked"]
    assert_equal [1, nil, 1, nil], [head, named, merge, other].map { |id| dirty(:gh_pr_checks, id) }
    run = { "head_sha" => "d" * 40, "pull_requests" => [{ "number" => 2 }, { "number" => "x" }, "junk"] }
    assert_equal 2, deliver("check_run", { "check_run" => run, "repository" => repo }).last["marked"]
    assert_equal 1, dirty(:gh_pr_checks, named)
    suite = { "head_sha" => SHA, "pull_requests" => [] }
    assert_equal 2, deliver("check_suite", { "check_suite" => suite, "repository" => repo }).last["marked"]
    assert_nil dirty(:gh_pr_states, state), "a check changes no PR state"
  end

  def test_refusals_in_order_and_ignored_events
    big = { "pad" => "x" * 5000 }
    assert_equal 413, deliver("pull_request", big).first
    # a lying Content-Length: the body read is capped all the same
    assert_equal 413, deliver("pull_request", big, extra: { "CONTENT_LENGTH" => "10" }).first
    assert_equal [400, { "error" => "no X-GitHub-Event header" }], deliver(nil, pr_event(1))
    assert_equal [200, { "ok" => "pong" }], deliver("ping", { "zen" => "hi" })
    assert_equal [204, nil], deliver("issues", { "action" => "opened" })
    assert_equal 401, deliver("issues", { "action" => "opened" }, signature: nil).first, "signature before the event"
    assert_equal 415, deliver("pull_request", "payload=%7B%7D", type: "application/x-www-form-urlencoded").first
    assert_equal 400, deliver("pull_request", "{nope").first
    assert_equal 400, deliver("pull_request", "[1]").first
    { { "number" => 1 } => /full_name/, { "number" => 0, "repository" => { "full_name" => "o/r" } } => /PR number/,
      { "number" => 1, "repository" => { "full_name" => "o/r/../x" } } => /full_name/, }.each do |bad, msg|
      status, body = deliver("pull_request", bad)
      assert_equal 400, status
      assert_match msg, body["error"]
    end
    assert_match(/commit sha/, deliver("status", { "sha" => "zz", "repository" => { "full_name" => "o/r" } }).last["error"])
    assert_match(/no check_run object/, deliver("check_run", { "repository" => { "full_name" => "o/r" } }).last["error"])
  end

  # GitHub sends the public Host and no Origin / Referer: HostGuard lets it through to the endpoint, and still refuses
  # a foreign Host before it runs
  def test_host_guard_still_applies
    origins = Busyyaks::HostGuard.origins({ "WEB_HOST_PORT" => "4100", "PUBLIC_HOST" => "busy.example.com" },
                                          provider: Object.new)
    app = Busyyaks::HostGuard.new(@hook, origins)
    assert_equal 200, deliver("ping", {}, app: app).first
    assert_equal 421, deliver("ping", {}, app: app, extra: { "HTTP_HOST" => "evil.example" }).first
    assert_equal 403, deliver("ping", {}, app: app, extra: { "HTTP_ORIGIN" => "https://evil.example" }).first
  end

  def test_settings_and_boot_check
    assert_nil H.parse!("none")
    assert_equal 5, H.parse!({ "max_body_bytes" => 1024, "wake_seconds" => 5 }).wake_seconds
    [nil, "on", {}, { "max_body_bytes" => 1024 }, { "max_body_bytes" => 10, "wake_seconds" => 5 },
     { "max_body_bytes" => (1024 * 1024) + 1, "wake_seconds" => 5 },
     { "max_body_bytes" => 1024, "wake_seconds" => 0 }, { "max_body_bytes" => 1024, "wake_seconds" => "5" },
     { "max_body_bytes" => 1024, "wake_seconds" => 5, "x" => 1 },].each do |bad|
      assert_raises(H::Invalid, bad.inspect) { H.parse!(bad) }
    end

    assert_match(/not in the web service's env/, assert_raises(H::Invalid) { H.boot!(nil, {}) }.message)
    assert_nil H.boot!(nil, { H::SECRET => "" })
    assert_match(/set but .* github_hook is none/, assert_raises(H::Invalid) { H.boot!(nil, { H::SECRET => SECRET }) }.message)
    ["", "short", "#{'s' * 40} x"].each do |bad|
      assert_raises(H::Invalid, bad) { H.boot!(SETTINGS, { H::SECRET => bad }) }
    end
    assert_equal SECRET, H.boot!(SETTINGS, { H::SECRET => SECRET })
    assert_raises(H::Invalid) { H::Endpoint.new(secret: "", settings: SETTINGS, wanted_for: -> { 600 }) }
  end

  # off (the suite's config: github_hook none) → no route at all
  def test_off_means_no_route
    status, = Hanami.app.call("REQUEST_METHOD" => "POST", "PATH_INFO" => H::PATH, "rack.input" => StringIO.new("{}"),
                              "HTTP_HOST" => "127.0.0.1:#{ENV.fetch('WEB_HOST_PORT')}", "HTTP_X_GITHUB_EVENT" => "ping")
    assert_equal 404, status
  end

  class FakeHttp
    attr_reader :requests

    def initialize(pulls) = (@pulls = pulls; @requests = [])

    def get(url, _headers)
      @requests << url
      n = url[%r{/pulls/(\d+)\z}, 1]&.to_i
      pr = @pulls[n]
      return [404, {}, "{}"] unless pr

      [200, { "etag" => "\"e#{n}#{pr['state']}\"" }, JSON.generate(pr)]
    end
  end

  def pull(n, state) = { "number" => n, "state" => state, "draft" => false, "merged_at" => nil,
                         "html_url" => "https://github.com/o/r/pull/#{n}", }

  def test_the_dirty_pass_polls_only_marked_rows_and_clears_the_mark_it_read
    http = FakeHttp.new(1 => pull(1, "closed"), 2 => pull(2, "closed"))
    client = Busyyaks::GithubNetwork::Client.new(token: "t", http: http)
    gate = Busyyaks::GithubPollers.new(db: @db, clock: -> { @now })
    states = Busyyaks::PrStates::Poller.new(db: @db, client: client, gate: gate, wanted_for: 600, clock: -> { @now })
    checks = Busyyaks::CiChecks::Poller.new(db: @db, client: client, gate: gate, wanted_for: 600,
                                            ci: Busyyaks::CiSettings.parse!(CI_SETTINGS), clock: -> { @now })
    s1 = row(:gh_pr_states, "o/r", "pr:1")
    s2 = row(:gh_pr_states, "o/r", "pr:2")
    c1 = row(:gh_pr_checks, "o/r", "pr:1")
    c2 = row(:gh_pr_checks, "o/r", "pr:2")
    assert_equal 0, states.run(dirty: true) + checks.run(dirty: true), "nothing marked → nothing read"
    assert_empty http.requests

    deliver("pull_request", pr_event(1, "o/r"))
    assert_equal 1, states.run(dirty: true)
    assert_equal 1, checks.run(dirty: true)
    assert_equal ["/repos/o/r/pulls/1"] * 2, http.requests.map { |u| u.delete_prefix("https://api.github.com") }
    assert_equal ["closed", nil], [@db[:gh_pr_states].where(id: s1).get(:state), @db[:gh_pr_states].where(id: s2).get(:state)]
    assert_equal ["closed", nil], [@db[:gh_pr_checks].where(id: c1).get(:state), @db[:gh_pr_checks].where(id: c2).get(:state)]
    assert_nil dirty(:gh_pr_states, s1)
    assert_nil dirty(:gh_pr_checks, c1)

    # a hook landing while the row is polled keeps its mark: the clear names the counter it selected
    H.clean(@db[:gh_pr_states], { id: s2, dirty: 1 })
    H.bump(@db[:gh_pr_states].where(id: s2))
    H.bump(@db[:gh_pr_states].where(id: s2))
    H.clean(@db[:gh_pr_states], { id: s2, dirty: 1 })
    assert_equal 2, dirty(:gh_pr_states, s2)
    # a full run reads every wanted row and clears their marks too
    assert_equal 2, states.run
    assert_nil dirty(:gh_pr_states, s2)
  end

  # a hook landing while the pass that makes a row final reads it leaves a mark no later pass reads: the next pass
  # clears it, so the waker stops waking for it
  def test_a_mark_left_on_a_row_that_turned_final_is_cleared
    http = FakeHttp.new(1 => pull(1, "closed").merge("merged_at" => "2026-01-01T00:00:00Z"))
    client = Busyyaks::GithubNetwork::Client.new(token: "t", http: http)
    gate = Busyyaks::GithubPollers.new(db: @db, clock: -> { @now })
    states = Busyyaks::PrStates::Poller.new(db: @db, client: client, gate: gate, wanted_for: 600, clock: -> { @now })
    id = row(:gh_pr_states, "o/r", "pr:1")
    @db[:gh_pr_states].where(id: id).update(state: "merged", checked_at: @now, dirty: 2)
    waker = H::Waker.new(db: @db, settings: SETTINGS, wanted_for: 600, now: -> { @now })
    assert waker.dirty?
    assert_equal 0, states.run(dirty: true), "a final row is not read again"
    assert_empty http.requests
    assert_nil dirty(:gh_pr_states, id)
    refute waker.dirty?
  end

  def test_a_request_without_a_body_is_refused_not_an_error
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => H::PATH, "CONTENT_TYPE" => "application/json",
            "HTTP_HOST" => "busy.example.com", "HTTP_X_GITHUB_EVENT" => "ping", "HTTP_X_HUB_SIGNATURE_256" => sign(""), }
    status, = @hook.call(env)
    refute_equal 500, status
    status, = @hook.call(env.merge("HTTP_X_HUB_SIGNATURE_256" => "sha256=#{'0' * 64}"))
    assert_equal 401, status
  end

  def test_the_wait_wakes_the_pollers_on_a_dirty_row_and_keeps_the_interval
    t = 0.0
    slept = []
    wakes = 0
    make = lambda do |settings|
      H::Waker.new(db: @db, settings: settings, wanted_for: 600, sleeper: ->(s) { slept << s; t += s },
                   clock: -> { t }, now: -> { @now })
    end
    make.call(nil).wait(60) { wakes += 1 }
    assert_equal [[60], 0], [slept, wakes], "hook off: one plain sleep, never a dirty check"

    slept.clear
    id = row(:gh_pr_states, "o/r", "pr:1")
    waker = make.call(H::Settings.new(max_body_bytes: 4096, wake_seconds: 25))
    waker.wait(60) { wakes += 1 }
    assert_equal [[25, 25, 10], 0], [slept, wakes], "no dirty row: the interval in wake_seconds steps"

    slept.clear
    @db[:gh_pr_states].where(id: id).update(dirty: 1)
    waker.wait(60) do
      wakes += 1
      @db[:gh_pr_states].where(id: id).update(dirty: nil)
    end
    assert_equal [[25, 25, 10], 1], [slept, wakes]

    @db[:gh_pr_states].where(id: id).update(dirty: 1, requested_at: @now - 601)
    refute waker.dirty?, "a row out of the pollers' window would not be polled: no wake for it"
  end
end
