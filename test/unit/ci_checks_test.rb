# frozen_string_literal: true

require "test_helper"
require "stringio"
require "uri"
require "digest"
require "busyyaks/kanban"
require "busyyaks/ci_checks"

# The idle watch on busyyaks's wiring: Port (notifier side) + Poller (github side) over gh_pr_checks, into the engine's
# Notifier. A fake api.github.com and a fake launcher; the engine's own rules are tested in the vendored suite.
class CiChecksTest < Minitest::Test
  include DBReset
  CK = Busyyaks::CiChecks

  class FakeHttp
    attr_accessor :pulls, :statuses, :runs, :requests, :statuses_by_sha, :heads, :compare
    def initialize = (@requests = []; @pulls = []; @statuses = []; @runs = []; @statuses_by_sha = {}; @heads = {})
    def get(url, headers)
      raise "no token" unless headers["Authorization"]
      @requests << url
      body = case url
             when %r{/pulls\?state=open&head=} then @pulls
             when %r{/pulls/(\d+)\z} then @pulls.find { |p| p["number"] == Regexp.last_match(1).to_i }
             when %r{/commits/([^/]+)/status\z} then { "statuses" => @statuses_by_sha.fetch(Regexp.last_match(1), @statuses) }
             when %r{/branches/([^/?]+)\z}
               sha = @heads[Regexp.last_match(1)]
               sha && { "commit" => { "sha" => sha } }
             when %r{/compare/} then @compare && { "status" => @compare }
             when %r{/check-runs} then { "check_runs" => @runs }
             end
      return [404, {}, "{\"message\":\"Not Found\"}"] if body.nil?

      json = JSON.generate(body)
      etag = "\"#{Digest::SHA1.hexdigest(json)}\""
      return [304, {}, ""] if headers["If-None-Match"] == etag # GitHub: unchanged since that ETag, not rate-counted

      [200, { "etag" => etag }, json]
    end
  end

  class FakeLauncher
    attr_accessor :branch, :commit
    def git(session:, socket:) = { "ok" => true, "branch" => @branch, "last_commit_at" => @commit }
    def notify(session:, socket:, text:) = (sent << [session, text]; { "ok" => true })
    def sent = (@sent ||= [])
    def sessions = [{ "name" => "shop" }]
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def dialog(**) = { "ok" => true, "dialog" => nil }
  end

  PR = { "number" => 112, "state" => "open", "head" => { "sha" => "abc" } }.freeze

  def setup
    super
    @conn = Hanami.app["db.gateway"].connection
    @conn[:projects].insert(slug: "o-r", path: "/projects/r", remote: "git@github.com:o/r.git",
                            pr_remote: "git@github.com:o/r.git", own: true, commits_window: 0, mine_window: 0, dirty: 0,
                            scanned_at: 0)
    @now = 1_000_000
    @http = FakeHttp.new
    @launcher = FakeLauncher.new
    @launcher.branch = "feat/x"
    @client = client = Busyyaks::GithubNetwork::Client.new(token: "t", http: @http)
    @poller = CK::Poller.new(db: @conn, client: client, wanted_for: 600, clock: -> { @now })
    @port = CK::Port.new(db: @conn, projects: ->(s) { @conn[:projects].where(slug: s).first },
                         approvals: ->(s) { @kb.board_of(s).approvals.map(&:to_h) }, launcher: @launcher,
                         stale_after: 180, wanted_for: 600, clock: -> { @now })
    @kb = Busyyaks::Kanban.store(@conn, clock: -> { @now })
    @id = @kb.create(slug: "o-r", title: "ship", by: "lead", column: "doing")
    @kb.update(@id, { "assignee" => "lead" }, by: "lead")
    @kb.set_owner(@id, session: "shop", by: "lead")
    @card = @kb.card(@id)
  end

  def finish_at(t) = Time.at(t).utc.iso8601

  def test_branch_without_pr_is_nothing_and_asks_once
    assert_equal({ number: nil, state: "unpolled", finished_at: nil }, @port.pr_checks(@card))
    @poller.run
    assert_nil @port.pr_checks(@card), "no open PR on the branch"
    assert_equal 1, @conn[:gh_pr_checks].count
    assert_includes @http.requests.first, "head=o%3Afeat%2Fx"
  end

  # the branch's PR is looked up on the repo it is pushed to (pr_remote), not origin
  def test_branch_pr_is_read_from_the_push_remote
    @conn[:projects].where(slug: "o-r").update(pr_remote: "git@github.com:o/r_local.git")
    @port.pr_checks(@card)
    @poller.run
    assert_includes @http.requests.first, "/repos/o/r_local/pulls"
  end

  def test_success_failure_and_pending
    @http.pulls = [PR]
    @port.pr_checks(@card)
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(@now - 50) }]
    @poller.run
    assert_equal "pending", @port.pr_checks(@card)[:state]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now - 50) }]
    @http.runs = [{ "status" => "completed", "conclusion" => "success", "completed_at" => finish_at(@now - 20) }]
    @poller.run
    assert_equal({ number: 112, state: "success", finished_at: @now - 20, head: "abc" }, @port.pr_checks(@card))
    @http.runs = [{ "status" => "completed", "conclusion" => "failure", "completed_at" => finish_at(@now - 20) }]
    @poller.run
    assert_equal "failure", @port.pr_checks(@card)[:state]
  end

  def test_card_pr_url_wins_over_the_branch
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r/pull/112")
    @http.pulls = [PR]
    @port.pr_checks(@kb.card(@id))
    @poller.run
    assert @http.requests.any? { |u| u.end_with?("/repos/o/r/pulls/112") }
  end

  # the approval gate's port. A non-final step reads the card's own PR; the final step of a enrolled
  # project reads the public pub/card-<id> PR (head = public_head's owner); an enrolment without a public repo is said.
  def test_approval_checks_read_the_step_s_pr
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r_local/pull/112")
    card = @kb.card(@id)
    local_step = { from: "human_check", to: "local_merged_pr", then: "deploy_check", name: "Approve", final: false }
    public_step = { from: "public_review", to: "ready", then: "merged", name: "PR approved", final: true }
    assert_equal "unpolled", @port.approval_checks(card, local_step)[:state]
    assert_equal "unpolled", @port.approval_checks(card, public_step)[:state],
                 "not enrolled: the final step reads the card's PR"
    assert_equal [%w[o/r_local pr:112]], @conn[:gh_pr_checks].select_map(%i[repo ref])

    @http.pulls = [PR]
    @poller.run
    enrol!
    blocked = @port.approval_checks(card, public_step)
    assert_equal "blocked", blocked[:state]
    assert_match(/the local PR #112 is still open, not merged into the local repo/, blocked[:reason])
    refute_includes @conn[:gh_pr_checks].select_map(%i[repo ref]), ["o/r", "head:o:pub/card-#{@id}"],
                    "the public PR is not asked before the local PR is merged"
    @http.pulls = [PR.merge("number" => 5), PR.merge("state" => "closed", "merged_at" => "2026-11-09T10:00:00Z")]
    @poller.run
    assert_equal "unpolled", @port.approval_checks(card, public_step)[:state], "merged: now the public PR is asked"
    assert_includes @conn[:gh_pr_checks].select_map(%i[repo ref]), ["o/r", "head:o:pub/card-#{@id}"]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now - 5) }]
    @poller.run
    head = URI.encode_www_form_component("o:pub/card-#{@id}")
    assert(@http.requests.any? { |u| u.end_with?("/repos/o/r/pulls?state=open&head=#{head}") })
    assert_equal({ number: 5, state: "success", finished_at: @now - 5, head: "abc" }, @port.approval_checks(card, public_step))
    assert_equal "the local PR #112 was merged before its approval", @port.approval_checks(card, local_step)[:reason],
                 "the first gate needs the local PR open: merged ahead of the operator is refused"

    @conn[:projects].where(slug: "o-r").update(public_repo: nil, public_head: nil, local_error: "no fork remote yet")
    e = assert_raises(CK::Unavailable) { @port.approval_checks(card, public_step) }
    assert_match(/public PR of card ##{@id} cannot be found: no fork remote yet/, e.message)
  end

  def enrol!
    @conn[:projects].where(slug: "o-r").update(local_mode: "own", local_repo: "git@github.com:o/r_local.git",
                                               public_repo: "git@github.com:o/r.git", public_head: "git@github.com:o/r.git")
  end

  def test_public_step_needs_a_local_pr_and_says_closed_unmerged
    enrol!
    step = { from: "public_review", to: "ready", then: "merged", name: "PR approved", final: true }
    e = assert_raises(CK::Unavailable) { @port.approval_checks(@card, step) }
    assert_match(/card ##{@id} has no local PR/, e.message)
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r_local/pull/112")
    card = @kb.card(@id)
    assert_match(/local PR #112 is not read yet/, @port.approval_checks(card, step)[:reason])
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil)]
    @poller.run
    assert_match(/local PR #112 is closed without merging/, @port.approval_checks(card, step)[:reason])
  end

  # local v3: the board's first approval (Local: Human review) = the open local PR's checks; Local: Deploy check →
  # Open public PR = the local PR merged + jenkins/ci of its MERGE commit (on the working branch) green. The steps are
  # the board's own approvals (Board#approvals), not written by hand.
  def local_v3_steps
    enrol!
    v3 = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/local_v3.board.json", __dir__)))
    @kb.board_save("o-r", v3, by: "operator")
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r_local/pull/112")
    steps = @kb.board_of("o-r").approvals.map(&:to_h)
    assert_equal %w[local_human_review deploy_check public_human_review], steps.map { |s| s[:from] }
    [@kb.card(@id), steps[0], steps[1]]
  end

  MERGED = PR.merge("state" => "closed", "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "m1" * 20,
                    "base" => { "ref" => "local" }).freeze

  def test_local_deploy_check_reads_the_merge_commits_ci
    card, first, deploy = local_v3_steps
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @port.approval_checks(card, first)
    @poller.run
    assert_equal "success", @port.approval_checks(card, first)[:state], "first gate: the open local PR is green"
    assert_match(/the local PR #112 is still open/, @port.approval_checks(card, deploy)[:reason])
    @http.pulls = [MERGED]
    @poller.run
    assert_equal "unpolled", @port.approval_checks(card, deploy)[:state], "merged: the merge commit's CI is asked"
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    @poller.run
    assert_equal "jenkins/ci for the local PR #112 merge is pending: merge commit m1m1m1m",
                 @port.approval_checks(card, deploy)[:reason]
    assert(@http.requests.any? { |u| u.end_with?("/repos/o/r_local/commits/#{'m1' * 20}/status") }, "the merge commit")
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @poller.run
    assert_equal [112, "success"], @port.approval_checks(card, deploy).values_at(:number, :state)
    assert_equal "the local PR #112 was merged before its approval", @port.approval_checks(card, first)[:reason]
  end

  # Jenkins coalesces the working branch's builds: a merge commit with no checks of its own passes on the branch HEAD's
  # green jenkins/ci only when that head CONTAINS it (compare: ahead / identical); otherwise refused naming both shas.
  def test_a_coalesced_merge_commit_passes_on_a_green_head_that_contains_it
    card, _first, deploy = local_v3_steps
    @http.pulls = [MERGED]
    @http.statuses_by_sha["m1" * 20] = []
    @http.heads["local"] = "h2" * 20
    @http.statuses_by_sha["h2" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @http.compare = "diverged"
    2.times do # the local PR's merge is read first, then its merge commit's CI is asked
      @port.approval_checks(card, deploy)
      @poller.run
    end
    assert_equal "jenkins/ci for the local PR #112 merge is nochecks: merge commit m1m1m1m has no checks and local " \
                 "head h2h2h2h does not contain it (compare: diverged)", @port.approval_checks(card, deploy)[:reason]
    @http.compare = "ahead"
    @poller.run
    assert_equal [112, "success"], @port.approval_checks(card, deploy).values_at(:number, :state)
    assert_equal "merge commit m1m1m1m has no checks of its own; read local head h2h2h2h, which contains it",
                 @conn[:gh_pr_checks].where(ref: "merge:112").get(:detail)
    assert(@http.requests.any? { |u| u.end_with?("/repos/o/r_local/compare/#{'m1' * 20}...#{'h2' * 20}") })
    @http.statuses_by_sha["h2" * 20] = [{ "state" => "failure", "updated_at" => finish_at(@now) }]
    @poller.run
    red = @port.approval_checks(card, deploy)
    assert_match(/merge is failure: merge commit m1m1m1m has no checks of its own; read local head h2h2h2h/, red[:reason])
    assert_equal "failure", red[:state], "red stays red (card #248: the gate watch pings the owner on state failure)"
    @http.heads["local"] = "m1" * 20 # the merge commit is the head and has no checks yet
    @poller.run
    assert_match(/merge is nochecks: merge commit m1m1m1m \(the head of local\) has no checks/,
                 @port.approval_checks(card, deploy)[:reason])
  end

  def test_the_first_gate_says_closed_without_merging
    card, first, = local_v3_steps
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil)]
    @port.approval_checks(card, first)
    @poller.run
    assert_equal "the local PR #112 was closed without merging", @port.approval_checks(card, first)[:reason]
  end

  # the public loop's handoff puts the PUBLIC PR in pr_url: the local PR is then the newest handoff naming a PR on
  # the local repo (never the public PR read as the local one); no local PR anywhere → Unavailable, said
  def test_the_local_pr_comes_from_the_handoffs_once_pr_url_is_the_public_pr
    enrol!
    step = { from: "public_human_review", to: "awaiting_merge", then: "done", name: "Approve", final: true }
    @conn[:card_activity].insert(card_id: @id, kind: "handoff", author: "reviewer", created_at: @now,
                                 body: "handed to Local: Human review: PR https://github.com/o/r_local/pull/112 · CI https://ci.example.com/1")
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r/pull/7")
    card = @kb.card(@id)
    assert_match(/the local PR #112 is not read yet/, @port.approval_checks(card, step)[:reason])
    assert_includes @conn[:gh_pr_checks].select_map(%i[repo ref]), %w[o/r_local pr:112]
    refute_includes @conn[:gh_pr_checks].select_map(%i[repo ref]), %w[o/r pr:7]
    @conn[:card_activity].where(card_id: @id, kind: "handoff").delete
    e = assert_raises(CK::Unavailable) { @port.approval_checks(card, step) }
    assert_equal "card ##{@id} has no local PR (a PR on o/r_local in its pr_url or a handoff)", e.message
  end

  # a request the github service stopped polling (older than wanted_for) is asked afresh — not
  # reported as "service stopped"; inside the window an old answer still is.
  def test_a_request_outside_the_poll_window_is_asked_again
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r/pull/112")
    card = @kb.card(@id)
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @port.pr_checks(card)
    @poller.run
    @now += 601
    assert_equal "unpolled", @port.pr_checks(card)[:state]
    @poller.run
    assert_equal "success", @port.pr_checks(card)[:state]
    @now += 181
    assert_raises(CK::Unavailable) { @port.pr_checks(card) }
  end

  # end to end on a local (v3) board: the Store refuses the final approval (Public: Human review → Awaiting merge)
  # while the local PR is open, then on the public PR's CI; a failed or stale read is refused as unknown, never guessed.
  def test_the_store_gates_the_public_step_on_the_local_merge_and_the_public_ci
    enrol!
    v3 = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/local_v3.board.json", __dir__)))
    @kb.board_save("o-r", v3, by: "operator")
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r_local/pull/112", column: "public_human_review")
    refuse = lambda do |pattern, drag: false|
      e = assert_raises(AgentsKanban::Invalid) do
        drag ? @kb.move(@id, column: "awaiting_merge", by: "operator") : @kb.approve(@id, by: "operator")
      end
      assert_match(pattern, e.message)
      assert_equal ["public_human_review", nil], @kb.card(@id).values_at(:column, :approved_at)
    end
    unread = "the local PR #112 is not read yet (asked now — try again in a minute)" # an approval or a handoff
    refuse.call(/Public: Human review → Awaiting merge\): card ##{@id} — #{Regexp.escape(unread)}\z/)
    @http.pulls = [PR]
    @poller.run
    refuse.call(/the local PR #112 is still open/, drag: true)
    @http.pulls = [PR.merge("number" => 5), PR.merge("state" => "closed", "merged_at" => "2026-11-09T10:00:00Z")]
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    @poller.run
    refuse.call(/its PR of card ##{@id} — CI not read yet/)
    @poller.run
    refuse.call(/PR #5 of card ##{@id} — CI is still running/, drag: true)
    @http.define_singleton_method(:get) { |*| [401, {}, '{"message":"Bad credentials"}'] }
    @poller.run
    refuse.call(/CI state of card ##{@id} is unknown — GitHub check poll .* failed/)
  end

  # end to end (card #247, the operator: "Mirror: Human review should be after CI passes, not before!"): busyyaks's
  # Store is built with the port (config approval.requires_green_ci), so the HANDOFF into the gate is refused until the
  # github service read the PR's checks green — and the operator's Approve right after it answers at once.
  def test_the_handoff_waits_for_green_ci_and_approve_then_answers_at_once
    hand = -> { @kb.handoff(@id, qa: "open the board and check the card moves", pr_url: "https://github.com/o/r/pull/112",
                                 ci_url: "https://ci.example.com/job/r/1/", ui_change: false, by: "lead") }
    refused = lambda do |said|
      e = assert_raises(AgentsKanban::Invalid) { hand.call }
      assert_match(/\Anot handed off \(→ .+\): #{said}; hand off once CI is green\z/, e.message)
      assert_equal ["doing", nil], @kb.card(@id).values_at(:column, :handoff_at)
    end
    refused.call(/its PR of card ##{@id} — CI not read yet \(asked now — hand off again in a minute\)/)
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    @poller.run
    refused.call(/PR #112 of card ##{@id} — CI is still running/)
    @http.statuses = [{ "state" => "failure", "updated_at" => finish_at(@now) }]
    @poller.run
    refused.call(/PR #112 of card ##{@id} — CI failed/)
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @poller.run
    hand.call
    step = @kb.board_of("o-r").approvals.first
    assert_equal step.from, @kb.card(@id)[:column]
    @kb.approve(@id, by: "operator")
    assert_equal [step.to, "operator"], @kb.card(@id).values_at(:column, :approved_by)
  end

  # card #247: the notifier's watch pass keeps every gated card's approval checks asked (the engine's approval
  # prefetch), so the github service always holds a fresh answer — a card handed off 30 min ago, far past the poll
  # window, is approved on the FIRST click; red or pending is still refused with its state; a card that left the gate
  # drops out of the poll.
  # the agent's handoff on green CI: the first try asks (refused, not read yet), the github service polls, the retry
  # passes
  def handoff!
    2.times do
      return @kb.handoff(@id, qa: "open the board and check the card moves", pr_url: "https://github.com/o/r/pull/112",
                              ci_url: "https://ci.example.com/job/r/1/", ui_change: false, by: "lead")
    rescue AgentsKanban::Invalid => e
      raise unless e.message.include?("CI not read yet")

      @poller.run
    end
    flunk "handoff refused twice"
  end

  # the compose cadences: a watch pass every 30 s (NOTIFIER_WATCH_SECONDS), a poll every 60 s (GITHUB_CI_INTERVAL_SECONDS)
  def run_services_for(seconds)
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: StringIO.new)
    (seconds / 30).times do |i|
      @now += 30
      n.watch
      @poller.run if i.odd?
    end
  end

  def test_a_card_handed_off_30_min_ago_is_approved_on_the_first_click
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    handoff!
    assert_equal [%w[o/r pr:112]], @conn[:gh_pr_checks].select_map(%i[repo ref]), "the handoff asked"
    run_services_for(1800)
    step = @kb.board_of("o-r").approvals.first
    @kb.approve(@id, by: "operator")
    assert_equal [step.to, "operator"], @kb.card(@id).values_at(:column, :approved_by)
  end

  # CI re-run on the gated card (a new push, a rebuild) goes pending or red: the Approve says so on the first click
  def test_a_gated_card_s_red_or_pending_ci_is_refused_with_its_state_on_the_first_click
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    handoff!
    { "pending" => /PR #112 .* CI is still running/, "failure" => /PR #112 .* CI failed/ }.each do |state, pattern|
      @http.statuses = [{ "state" => state, "updated_at" => finish_at(@now) }]
      run_services_for(1800)
      assert_match(pattern, assert_raises(AgentsKanban::Invalid) { @kb.approve(@id, by: "operator") }.message)
    end
  end

  def test_a_card_that_left_the_gate_is_no_longer_polled
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    handoff!
    run_services_for(120)
    @kb.move(@id, column: "backlog", by: "operator") # parked: neither a gate nor the idle watch's working column
    run_services_for(1800)
    asked = @conn[:gh_pr_checks].where(repo: "o/r", ref: "pr:112").get(:requested_at)
    assert_operator @now - asked, :>, 600, "nobody asks for it any more"
    assert_equal 0, @poller.run, "outside the poll window: the github service stops polling it"
  end

  # a gated card is polled every minute for as long as it waits: an unchanged PR and checks cost no rate limit (304)
  def test_an_unchanged_gated_pr_costs_no_rate_limit
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    handoff!
    run_services_for(120)
    paid = @client.calls
    free = @client.not_modified
    assert_equal 3, paid, "pulls/N + status + check-runs, once"
    run_services_for(1800)
    assert_equal paid, @client.calls, "30 polls later: every read a 304"
    assert_equal free + (30 * 3), @client.not_modified
    @http.statuses = [{ "state" => "failure", "updated_at" => finish_at(@now) }]
    run_services_for(60)
    assert_equal paid + 1, @client.calls, "the changed status is read (the rest still 304)"
    assert_match(/CI failed/, assert_raises(AgentsKanban::Invalid) { @kb.approve(@id, by: "operator") }.message)
  end

  # the poller's ETag cache keeps only the fields it reads, and forgets a URL nobody read for the poll window
  def test_the_etag_cache_is_slim_and_pruned
    @http.pulls = [PR.merge("body" => "x" * 10_000, "head" => { "sha" => "abc", "repo" => { "big" => "y" * 10_000 } })]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now), "description" => "z" * 10_000 }]
    handoff!
    run_services_for(120)
    pages = -> { @conn[:gh_pages].where(Sequel.like(:url, "ci:%")).order(:url).select_map(%i[url items]) }
    assert_equal ["ci:/repos/o/r/commits/abc/check-runs?per_page=100", "ci:/repos/o/r/commits/abc/status",
                  "ci:/repos/o/r/pulls/112",], pages.call.map(&:first)
    assert_equal({ "number" => 112, "state" => "open", "head" => { "sha" => "abc" } },
                 JSON.parse(pages.call.last[1]))
    assert_operator pages.call.sum { |_, i| i.size }, :<, 300, "no PR body, no repo, no status description"
    run_services_for(1800)
    assert_equal 3, pages.call.size, "read every minute (304): kept"
    @kb.move(@id, column: "backlog", by: "operator")
    run_services_for(1260) # the last request lapses after 600 s, its pages 600 s after their last read
    assert_empty pages.call, "nobody read them for the poll window: deleted"
  end

  # card #248 on the local_v3 board (an enrolled project): the Local: Human review gate path — handed off on green
  # CI of the LOCAL PR, approvable now (counted, a review); its CI re-runs red → held, the owner pinged once; green
  # again → counted, "ready for your approval" once
  def local_gate!
    enrol!
    v3 = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/local_v3.board.json", __dir__)))
    @kb.board_save("o-r", v3, by: "operator")
    @conn[:cards].where(id: @id).update(column: "local_agent_review")
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    2.times do
      @kb.handoff(@id, qa: "open the board and check the card moves", pr_url: "https://github.com/o/r_local/pull/112",
                       ci_url: "https://ci.example.com/job/r/1/", ui_change: false, by: "lead")
      break
    rescue AgentsKanban::Invalid => e
      raise unless e.message.include?("CI not read yet")

      @poller.run
    end
    assert_equal %w[local_human_review abc], @kb.card(@id).values_at(:column, :gate_head)
  end

  def waiting_now = @kb.waiting_cards(["o-r"])
  def held_now = waiting_now.held.fetch("o-r", []).map { |c| c[:gate_hold] }
  def pings_now = @conn[:card_pings].where(card_id: @id, reason: "gate_red").count
  def gate_log = @conn[:card_activity].where(card_id: @id, kind: "gate").order(:id).select_map(:body)

  def test_the_local_human_review_gate_counts_only_while_approvable_now
    local_gate!
    run_services_for(120)
    assert_equal [@id], waiting_now.by_slug.fetch("o-r").map { |c| c[:id] }, "green: waiting for you"
    assert_empty held_now
    @http.statuses = [{ "state" => "failure", "updated_at" => finish_at(@now) }]
    run_services_for(120)
    assert_equal ["PR #112: CI failed"], held_now
    assert_nil waiting_now.by_slug["o-r"], "red: not waiting for you"
    assert_equal 1, pings_now, "the owner is pinged to fix it, once"
    run_services_for(300)
    assert_equal 1, pings_now
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    run_services_for(120)
    assert_empty held_now
    assert_equal ["waiting for CI: PR #112: CI failed — pinged shop",
                  "ready for your approval: Local: Human review, CI green (was: PR #112: CI failed)",], gate_log
    @kb.approve(@id, by: "operator")
    assert_equal "local_merged_pr", @kb.card(@id)[:column]
  end

  # new commits pushed after the handoff: the reviewer has not seen them — held, and Approve refused, even on green
  def test_new_commits_since_the_handoff_hold_the_card_and_refuse_the_approval
    local_gate!
    @http.pulls = [PR.merge("head" => { "sha" => "def" })]
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    run_services_for(120)
    assert_equal ["PR #112: CI is still running"], held_now
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    run_services_for(120)
    moved = "new commits since the handoff (abc → def): the reviewer has not seen them"
    assert_equal [moved], held_now
    e = assert_raises(AgentsKanban::Invalid) { @kb.approve(@id, by: "operator") }
    assert_equal "not approved (Local: Human review → Local: Merged): card ##{@id} — #{moved}; hand it back for review",
                 e.message
    assert_equal "local_human_review", @kb.card(@id)[:column]
  end

  def test_the_watch_pass_must_fit_the_poll_window
    Busyyaks::Kanban.watch_fits!(watch: 30, interval: 10)
    e = assert_raises(ArgumentError) { Busyyaks::Kanban.watch_fits!(watch: 600, interval: 10) }
    assert_match(/a watch pass every 600 s .* must be below 600 s/, e.message)
    e = assert_raises(ArgumentError) { Busyyaks::Kanban.watch_fits!(watch: 30, interval: 600) }
    assert_match(/NOTIFIER_INTERVAL_SECONDS=600/, e.message, "the deliver loop's sleep stretches the watch period too")
  end

  def test_failed_poll_and_stale_answers_are_unavailable_not_guessed
    @port.pr_checks(@card)
    @poller.run
    @now += 181
    assert_raises(CK::Unavailable) { @port.pr_checks(@card) } # the github service stopped answering
    @http.define_singleton_method(:get) { |*| [401, {}, '{"message":"Bad credentials"}'] }
    assert_raises(CK::Unavailable) { @port.pr_checks(@card) } # re-requests (touches requested_at) while still stale
    @poller.run
    e = assert_raises(CK::Unavailable) { @port.pr_checks(@card) }
    assert_match(/rejected GITHUB_TOKEN/, e.message)
  end

  def test_requested_but_never_polled_for_too_long_is_unavailable
    @port.pr_checks(@card)
    @now += 181
    assert_raises(CK::Unavailable) { @port.pr_checks(@card) }
  end

  def test_end_to_end_green_pings_the_owner_once_through_the_notifier
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now + 100) }]
    log = StringIO.new
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: log)
    n.watch # asks
    @poller.run
    @now += 100 + 600
    n.watch # nobody asked for 700 s > wanted_for: the poller rightly stopped; asked afresh, not "github stopped"
    refute_match(/idle watch skipped/, log.string)
    @poller.run
    n.watch
    n.deliver
    assert_equal 1, @launcher.sent.size, log.string
    assert_match(/CI on PR #112 finished \(success\) — hand off or fix/, @launcher.sent.first[1])
    @now += 30
    @poller.run
    n.watch
    n.deliver
    assert_equal 1, @launcher.sent.size, "one ping per CI completion"
  end

  def test_the_board_config_is_wired
    assert_equal({ ci_ping_after_minutes: 10, ci_comment_after_minutes: 20, owner_idle_hours: 4 },
                 Busyyaks::Kanban.config.idle_watch.to_h)
  end
end
