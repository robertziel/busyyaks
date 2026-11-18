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
    attr_accessor :pulls, :statuses, :runs, :requests, :statuses_by_sha, :heads, :compare, :short_by, :suites, :events
    def initialize
      @requests = []
      @pulls = []
      @statuses = []
      @runs = []
      @statuses_by_sha = {}
      @heads = {}
      @short_by = 0
      @suites = {}
    end

    # a status / run without the fields a test does not care about: the gating jenkins/ci context, posted when it
    # last changed, its build URL
    def status(s) = { "context" => "jenkins/ci", "created_at" => s["updated_at"], "target_url" => CI_URL }.merge(s)
    def run(r) = { "id" => 1, "name" => "jenkins/ci", "started_at" => r["completed_at"], "details_url" => CI_URL }.merge(r)

    # one page of a list GitHub counts (`total_count`); short_by = how many more it counts than it hands over
    def paged(url, key, all)
      q = URI.decode_www_form(URI("https://x#{url}").query.to_s).to_h
      per = Integer(q.fetch("per_page", 30))
      page = all.each_slice(per).to_a[Integer(q.fetch("page", 1)) - 1] || []
      { "total_count" => all.size + @short_by, key => page }
    end

    def get(url, headers)
      raise "no token" unless headers["Authorization"]
      @requests << url
      path = url.sub(/\?.*/, "")
      body = case path
             when %r{/pulls/(\d+)\z}
               pr = @pulls.find { |p| p["number"] == Regexp.last_match(1).to_i }
               # a closed PR has its closed_at (the PR watch tells each close once, keyed by it)
               pr && pr["state"] == "closed" ? { "closed_at" => "2026-11-16T23:06:57Z" }.merge(pr) : pr
             when %r{/issues/\d+/events}
               return [500, {}, "{\"message\":\"Server Error\"}"] if @events == :fail

               @events || [{ "event" => "closed", "actor" => { "login" => "octo" } }]
             when %r{/commits/([^/]+)/status\z}
               paged(url, "statuses", @statuses_by_sha.fetch(Regexp.last_match(1), @statuses).map { |x| status(x) })
             when %r{/branches/([^/?]+)\z}
               sha = @heads[Regexp.last_match(1)]
               sha && { "commit" => { "sha" => sha } }
             when %r{/compare/} then @compare && { "status" => @compare }
             when %r{/check-suites/(\d+)\z} then @suites[Regexp.last_match(1).to_i]
             when %r{/check-runs\z} then paged(url, "check_runs", @runs.map { |x| run(x) })
             end
      return [404, {}, "{\"message\":\"Not Found\"}"] if body.nil?

      json = JSON.generate(body)
      etag = "\"#{Digest::SHA1.hexdigest(json)}\""
      return [304, {}, ""] if headers["If-None-Match"] == etag # GitHub: unchanged since that ETag, not rate-counted

      [200, { "etag" => etag }, json]
    end
  end

  class FakeLauncher
    attr_accessor :commit
    def git(session:, socket:) = { "ok" => true, "last_commit_at" => @commit }
    def notify(session:, socket:, text:) = (sent << [session, text]; { "ok" => true })
    def sent = (@sent ||= [])
    def sessions = [{ "name" => "shop" }]
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def dialog(**) = { "ok" => true, "dialog" => nil }
  end

  CI_URL = "https://ci.example.com/job/r/1/" # the build every fake check names (the handoffs below hand it over)
  # an open PR on the local repo's working branch that merges cleanly (the gate reads base, draft, mergeable)
  PR = { "number" => 112, "state" => "open", "draft" => false, "head" => { "sha" => "abc" }, "base" => { "ref" => "local" },
         "mergeable" => true, "mergeable_state" => "clean", }.freeze
  PUB = PR.merge("number" => 5, "base" => { "ref" => "main" }).freeze # the public PR, on the public repo's main

  def setup
    super
    @conn = Hanami.app["db.gateway"].connection
    @conn[:projects].insert(slug: "o-r", path: "/projects/r", remote: "git@github.com:o/r.git",
                            pr_remote: "git@github.com:o/r.git", own: true, commits_window: 0, mine_window: 0, dirty: 0,
                            scanned_at: 0)
    @now = 1_000_000
    @http = FakeHttp.new
    @launcher = FakeLauncher.new
    @client = client = Busyyaks::GithubNetwork::Client.new(token: "t", http: @http)
    @gate = Busyyaks::GithubPollers.new(db: @conn, clock: -> { @now })
    @poller = CK::Poller.new(db: @conn, client: client, gate: @gate, wanted_for: 600, ci: ci_settings, clock: -> { @now })
    @port = CK::Port.new(db: @conn, projects: ->(s) { @conn[:projects].where(slug: s).first },
                         approvals: ->(s) { CK.steps(@kb.board_of(s)) }, launcher: @launcher,
                         stale_after: 180, wanted_for: 600, clock: -> { @now })
    @states = Busyyaks::PrStates::Poller.new(db: @conn, client: client, gate: @gate, wanted_for: 600, clock: -> { @now })
    @kb = Busyyaks::Kanban.store(@conn, clock: -> { @now })
    @id = @kb.create(slug: "o-r", title: "ship", by: "lead", column: "doing")
    @kb.update(@id, { "assignee" => "lead" }, by: "lead")
    @kb.set_owner(@id, session: "shop", by: "lead")
    assign!("pr", "https://github.com/o/r/pull/112") # the PR its agent opened (a test without one clears it)
    @card = @kb.card(@id)
  end

  def finish_at(t) = Time.at(t).utc.iso8601

  # config ci: jenkins/ci gates on both test repos, a check pending over 60 min is stuck
  def ci_settings = Busyyaks::CiSettings.parse!("max_pending_minutes" => 60,
                                                "required" => { "o/r" => ["jenkins/ci"], "o/r_local" => ["jenkins/ci"],
                                                                "o/eng_local" => ["jenkins/ci"], })

  # a card's PRs are the ones assigned to it (kanban_pr_assign → metadata prs, a list), nothing else
  def assign!(role, url) = @kb.assign_pr(@id, url: url, role: role, by: "lead")

  # no PR assigned → nothing asked: neither the owner's branch nor the pr_url is read as the card's PR
  def test_no_assigned_pr_is_nothing_and_asks_nothing
    # metadata prs is kanban_pr_assign's alone: the assignment is cleared in the row
    @conn[:cards].where(id: @id).update(metadata: nil, pr_url: "https://github.com/o/r/pull/112")
    assert_nil @port.pr_checks(@kb.card(@id))
    assert_equal 0, @conn[:gh_pr_checks].count
    assign!("pr", "https://github.com/o/r/pull/112")
    assert_equal({ number: nil, state: "unpolled", finished_at: nil }, @port.pr_checks(@kb.card(@id)))
    assert_equal [%w[o/r pr:112]], @conn[:gh_pr_checks].select_map(%i[repo ref])
  end

  # a plain project's card PR is read on the repo its URL names; an assignment that is no PR URL is said
  def test_the_assigned_pr_is_read_on_its_own_repo
    @port.pr_checks(@kb.card(@id))
    @poller.run
    assert_includes @http.requests.first, "/repos/o/r/pulls/112"
    @conn[:cards].where(id: @id).update(metadata: JSON.generate("prs" => [{ "url" => "#112", "role" => "pr" }]))
    e = assert_raises(CK::Unavailable) { @port.pr_checks(@kb.card(@id)) }
    assert_equal "card ##{@id} metadata prs has an entry that is no PR URL: " \
                 "#{{ 'url' => '#112', 'role' => 'pr' }.to_s.inspect}", e.message
  end

  # on an enrolled project the idle watch follows the card's `local` PR (never its `pr` / `public`);
  # an unreadable local repo is said
  def test_the_idle_watch_follows_the_local_pr_on_an_enrolled_project
    enrol!
    assert_nil @port.pr_checks(@kb.card(@id)), "a `pr` PR is not an enrolled card's"
    assign!("public", "https://github.com/o/r/pull/5")
    assert_nil @port.pr_checks(@kb.card(@id)), "nor the public one"
    assign!("local", "https://github.com/o/r_local/pull/112")
    @port.pr_checks(@kb.card(@id))
    assert_equal [%w[o/r_local pr:112]], @conn[:gh_pr_checks].select_map(%i[repo ref])
  end

  # a ref the pollers no longer ask (the old branch lookup) is an error on its row, never a request
  def test_a_branch_ref_is_not_polled
    @conn[:gh_pr_checks].insert(repo: "o/r", ref: "branch:feat/x", requested_at: @now)
    @poller.run
    assert_match(/o\/r branch:feat\/x: not a pr:<n> \/ merge:<n> ref/, @conn[:gh_pr_checks].get(:error))
    assert_empty @http.requests
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
    assert_equal({ number: 112, state: "success", finished_at: @now - 20, head: "abc", base: "local", draft: false,
                   merge_state: "clean", auto_merge: false, builds: [CI_URL], detail: "passed: jenkins/ci", },
                 @port.pr_checks(@card))
    @http.runs = [{ "status" => "completed", "conclusion" => "failure", "completed_at" => finish_at(@now - 20) }]
    @poller.run
    assert_equal "failure", @port.pr_checks(@card)[:state]
  end

  # the progress watch's evidence — the followed PR's head + that head's CI (a rebuild of the same head is a
  # new key), each branch the card names that the scanner saw; a project never scanned, a stale poll → Unavailable
  def test_progress_reads_the_pr_head_its_ci_and_the_named_branches
    @conn[:projects].where(slug: "o-r").update(branch_tips: JSON.generate("card/1-x" => %w[c1c1c1c1c1], "main" => %w[m1]),
                                               remote_heads: "[]")
    assert_equal [], @port.progress(@kb.card(@id)), "not polled yet, no branch named: nothing"
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(@now - 50) }]
    @poller.run
    @kb.comment(@id, body: "pushed to card/1-x.", author: "lead")
    got = @port.progress(@kb.card(@id))
    assert_equal [["pr head", "abc", "PR o/r#112 head abc"], ["ci", "abc pending #{CI_URL}", "CI pending on abc"],
                  ["branch card/1-x", "c1c1c1c1c1", "branch card/1-x at c1c1c1c"],],
                 got.map { |e| e.values_at(:kind, :key, :text) }
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now - 20) }]
    @poller.run
    ci = @port.progress(@kb.card(@id)).find { |e| e[:kind] == "ci" }
    assert_equal "abc success #{@now - 20} #{CI_URL}", ci[:key], "a finished check is a new key"
    assert_equal ["pr head", "ci", "branch card/1-x", "branch main"],
                 (@kb.update(@id, { "title" => "ship main" }, by: "lead") && @port.progress(@kb.card(@id))).map { |e| e[:kind] }
    # a base branch (the checkout's, a remote's default branch) moves with every other card's merge: never
    # this card's progress
    @conn[:projects].where(slug: "o-r").update(default_ref: "main")
    assert_equal ["pr head", "ci", "branch card/1-x"], @port.progress(@kb.card(@id)).map { |e| e[:kind] }
    # a plain (not enrolled) repo whose checkout sits on another branch: its remote's default branch (origin/HEAD →
    # main) still never counts
    @conn[:projects].where(slug: "o-r").update(default_ref: "card/2-y", remote_heads: JSON.generate(["main"]))
    assert_equal ["pr head", "ci", "branch card/1-x"], @port.progress(@kb.card(@id)).map { |e| e[:kind] }
    @conn[:projects].where(slug: "o-r").update(remote_heads: nil)
    e = assert_raises(CK::Unavailable) { @port.progress(@kb.card(@id)) }
    assert_equal "o-r has not been read by the scanner yet", e.message
    @conn[:projects].where(slug: "o-r").update(remote_heads: "[]")
    @conn[:projects].where(slug: "o-r").update(default_ref: "card/1-x", public_base: "main")
    assert_equal ["pr head", "ci"], @port.progress(@kb.card(@id)).map { |e| e[:kind] }
    assert_equal ["the card's PR head", "the CI on that head", "commits on the branches the card names"], @port.progress_kinds
    @conn[:projects].where(slug: "o-r").update(branch_tips: nil)
    e = assert_raises(CK::Unavailable) { @port.progress(@kb.card(@id)) }
    assert_equal "o-r has not been read by the scanner yet", e.message
    @now += 200 # past stale_after (180), inside the poll window (600)
    @conn[:projects].where(slug: "o-r").update(branch_tips: "{}", remote_heads: "[]")
    e = assert_raises(CK::Unavailable) { @port.progress(@kb.card(@id)) }
    assert_equal "GitHub check status for o/r pr:112 is 200s old (github service stopped?)", e.message
  end

  # a card with several PRs follows each one — the kinds name the PR, so one PR's push is never read
  # as another's
  def test_progress_follows_every_assigned_pr
    @conn[:projects].where(slug: "o-r").update(branch_tips: "{}", remote_heads: "[]")
    assign!("pr", "https://github.com/o/r/pull/7")
    @http.pulls = [PR, PR.merge("number" => 7, "head" => { "sha" => "def" })]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now - 50) }]
    @port.progress(@kb.card(@id))
    @poller.run
    got = @port.progress(@kb.card(@id))
    assert_equal [["pr head o/r#112", "abc", "PR o/r#112 head abc"], ["ci o/r#112", "CI success on abc (o/r#112)"],
                  ["pr head o/r#7", "def", "PR o/r#7 head def"], ["ci o/r#7", "CI success on def (o/r#7)"],],
                 got.map { |e| e[:kind].start_with?("ci") ? e.values_at(:kind, :text) : e.values_at(:kind, :key, :text) }
  end

  # the wiring: the notifier's watch pass runs the engine's progress watch on this Port — a quiet card pings its owner
  # naming the PR head, then gets the busyyaks comment, then counts as waiting
  def test_the_notifier_escalates_a_quiet_card_with_the_ports_evidence
    @conn[:projects].where(slug: "o-r").update(branch_tips: "{}", remote_heads: "[]")
    @http.pulls = [PR]
    @port.progress(@kb.card(@id))
    @poller.run
    @kb.progress_watch_pass # the head first seen now
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: StringIO.new)
    # the notifier's cadence: a watch pass a minute (the poller answers each pass's requests)
    step = lambda do |mins|
      mins.times do
        @now += 60
        @poller.run
        n.deliver
        n.watch
      end
    end
    step.call(30)
    ping = @conn[:card_pings].where(card_id: @id, reason: "progress").first
    assert_includes ping[:text], "PR o/r#112 head abc since"
    step.call(30)
    assert_equal 1, @conn[:card_activity].where(card_id: @id, author: "busyyaks", kind: "comment")
                                         .where(Sequel.like(:body, "**No progress**%")).count
    step.call(30)
    assert_equal 1, @kb.waiting_counts(["o-r"]).waiting["o-r"]
    assert_match(/\Ano progress for 90 min/, @kb.card(@id)[:progress_stale])
  end

  # the approval gate's port. Not enrolled: every step reads the card's `pr` PR. Enrolled: a non-final step reads
  # the `local` PR; the final step the `public` one; none assigned, one on another repo, or an enrolment without a
  # public repo is said.
  def test_approval_checks_read_the_step_s_pr
    card = @card
    local_step = { from: "human_check", to: "local_merged_pr", then: "deploy_check", name: "Approve", final: false }
    public_step = { from: "public_review", to: "ready", then: "merged", name: "PR approved", final: true }
    assert_equal "unpolled", @port.approval_checks(card, local_step)[:state]
    assert_equal "unpolled", @port.approval_checks(card, public_step)[:state],
                 "not enrolled: the final step reads the card's PR"
    assert_equal [%w[o/r pr:112]], @conn[:gh_pr_checks].select_map(%i[repo ref])

    enrol!
    e = assert_raises(CK::Unavailable) { @port.approval_checks(card, local_step) }
    assert_equal "card ##{@id} has no local PR assigned (kanban_pr_assign role local)", e.message,
                 "enrolled: the `pr` PR is not the local one"
    assign!("local", "https://github.com/o/r_local/pull/112")
    card = @kb.card(@id)
    @port.approval_checks(card, local_step)
    @http.pulls = [PR]
    @poller.run
    blocked = @port.approval_checks(card, public_step)
    assert_equal "blocked", blocked[:state]
    assert_match(/the local PR o\/r_local#112 is still open, not merged into the local repo/, blocked[:reason])
    refute_includes @conn[:gh_pr_checks].select_map(%i[repo ref]), %w[o/r pr:5],
                    "the public PR is not asked before the local PR is merged"
    @http.pulls = [PUB, PR.merge("state" => "closed", "merged_at" => "2026-11-09T10:00:00Z")]
    @poller.run
    e = assert_raises(CK::Unavailable) { @port.approval_checks(card, public_step) }
    assert_equal "card ##{@id} has no public PR assigned (kanban_pr_assign role public)", e.message,
                 "merged, no public PR assigned: refused, no branch name guessed"
    assign!("public", "https://github.com/o/r/pull/5")
    card = @kb.card(@id)
    assert_equal "unpolled", @port.approval_checks(card, public_step)[:state], "merged: now the public PR is asked"
    assert_includes @conn[:gh_pr_checks].select_map(%i[repo ref]), %w[o/r pr:5]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now - 5) }]
    @poller.run
    assert(@http.requests.any? { |u| u.end_with?("/repos/o/r/pulls/5") })
    assert_equal({ number: 5, state: "success", finished_at: @now - 5, head: "abc", base: "main", draft: false,
                   merge_state: "clean", auto_merge: false, builds: [CI_URL], detail: "passed: jenkins/ci", },
                 @port.approval_checks(card, public_step))
    assert_equal "the local PR o/r_local#112 was merged before its approval", @port.approval_checks(card, local_step)[:reason],
                 "the first gate needs the local PR open: merged ahead of the operator is refused"

  end

  LOCAL_STEP = { from: "human_check", to: "local_merged_pr", then: "deploy_check", name: "Approve", final: false }.freeze
  PUBLIC_STEP = { from: "public_review", to: "ready", then: "merged", name: "PR approved", final: true }.freeze

  # the first gate's answer for the local PR #112 as `pr` reads on GitHub (green checks)
  def local_gate(pr)
    enrol!
    assign!("local", "https://github.com/o/r_local/pull/112")
    @http.pulls = [pr]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now - 5) }]
    @port.approval_checks(@kb.card(@id), LOCAL_STEP)
    @poller.run
    @port.approval_checks(@kb.card(@id), LOCAL_STEP)
  end

  # the PR must be based on its side's branch (local → guard.localBranch, public → guard.publicBase's);
  # a stacked or retargeted PR is refused, and an enrolment that names no base refuses, never lets any base through
  def test_a_pr_not_on_its_base_branch_is_flagged_and_gated
    row = local_gate(PR.merge("base" => { "ref" => "feature/live-agent-status" }))
    assert_equal({ number: 112, state: "blocked", finished_at: nil,
                   reason: "the local PR #112 is based on feature/live-agent-status, not local", }, row)
    @http.pulls = [PR]
    @poller.run
    assert_equal "success", @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:state]

    # the public step: the public PR on main, not on a stacked branch
    assign!("public", "https://github.com/o/r/pull/5")
    @http.pulls = [PUB.merge("base" => { "ref" => "feature/x" }),
                   PR.merge("state" => "closed", "merged_at" => "2026-11-09T10:00:00Z"),]
    2.times { @port.approval_checks(@kb.card(@id), PUBLIC_STEP); @poller.run } # the local merge, then the public PR
    assert_equal "the public PR #5 is based on feature/x, not main",
                 @port.approval_checks(@kb.card(@id), PUBLIC_STEP)[:reason]

    @conn[:projects].where(slug: "o-r").update(public_base: nil, local_error: "guard.publicBase is not set")
    e = assert_raises(CK::Unavailable) { @port.approval_checks(@kb.card(@id), PUBLIC_STEP) }
    assert_equal "card ##{@id}: the public PR o/r's base branch is not known: guard.publicBase is not set", e.message
  end

  # the CI poll read a draft's checks like any PR's: a green draft could be approved
  def test_approval_refuses_a_draft_pr
    row = local_gate(PR.merge("draft" => true))
    assert_equal "blocked", row[:state]
    assert_equal "the local PR #112 is a draft", row[:reason]
    # a plain project's PR too (any base): its `pr` PR (o/r#112, assigned in setup)
    @conn[:projects].where(slug: "o-r").update(local_mode: nil)
    @port.approval_checks(@kb.card(@id), LOCAL_STEP)
    @poller.run
    assert_equal "the PR #112 is a draft", @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:reason]
    assert_equal "success", @port.pr_checks(@kb.card(@id))[:state], "the idle watch still reads its checks"
  end

  # conflicts are NOT refused: the green answer carries rebase: with the base and the base commit, the engine accepts
  # the approval marked needs rebase; GitHub's mergeable null (it is still computing) is refused as not read, never
  # guessed either way; behind is NOT refused (the working branch moves on every merge — a conflict never parks a card)
  def test_mergeable_state_is_tagged_and_null_is_computing
    sha = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
    dirty = PR.merge("mergeable" => false, "mergeable_state" => "dirty", "base" => { "ref" => "local", "sha" => sha })
    row = local_gate(dirty)
    assert_equal ["success", { state: "conflicts", base: "local", base_sha: sha }], row.values_at(:state, :rebase)
    assert_nil row[:reason]
    # red CI still refuses first: the engine never sees the rebase: of a red answer as approvable
    @http.statuses = [{ "state" => "failure", "updated_at" => finish_at(@now - 5) }]
    @poller.run
    assert_equal "failure", @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:state]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now - 5) }]
    # a conflicting row whose base commit was not read (GitHub gave none) is refused as not read, never guessed
    @http.pulls = [dirty.merge("base" => { "ref" => "local" })]
    @poller.run
    assert_equal ["blocked", "the local PR #112 has conflicts with local; its base commit is not read yet (asked now " \
                             "— try again in a minute)",],
                 @port.approval_checks(@kb.card(@id), LOCAL_STEP).values_at(:state, :reason)
    # auto-merge on a conflicting PR still refuses (its own reason)
    @http.pulls = [dirty.merge("auto_merge" => {})]
    @poller.run
    assert_match(/has GitHub auto-merge on/, @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:reason])
    # rebased: clean again → no rebase:
    @http.pulls = [PR.merge("base" => { "ref" => "local", "sha" => sha })]
    @poller.run
    assert_nil @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:rebase]
    @http.pulls = [PR.merge("mergeable_state" => "behind")]
    @poller.run
    assert_equal %w[success behind], @port.approval_checks(@kb.card(@id), LOCAL_STEP).values_at(:state, :merge_state),
                 "behind: approvable, the rail warns"
    { { "mergeable" => nil, "mergeable_state" => "unknown" } =>
        "GitHub is still computing whether the local PR #112 merges cleanly (asked now — try again in a minute)",
      { "mergeable" => true, "mergeable_state" => "unknown" } =>
        "GitHub is still computing whether the local PR #112 merges cleanly (asked now — try again in a minute)", }
      .each do |fields, reason|
        @http.pulls = [PR.merge(fields)]
        @poller.run
        assert_equal ["blocked", reason], @port.approval_checks(@kb.card(@id), LOCAL_STEP).values_at(:state, :reason)
      end
    # mergeable, GitHub's word kept, never "clean": unstable = its checks not all green
    # (CI's call), blocked = branch rules (the board's approval is the review), has_hooks — the gate does not refuse
    # them, as before
    %w[unstable blocked has_hooks].each do |state|
      @http.pulls = [PR.merge("mergeable_state" => state)]
      @poller.run
      assert_equal ["success", state], @port.approval_checks(@kb.card(@id), LOCAL_STEP).values_at(:state, :merge_state),
                   state
    end
    # a value busyyaks does not know is refused with it, never passed as if it merged
    @http.pulls = [PR.merge("mergeable_state" => "some_new_state")]
    @poller.run
    assert_equal ["blocked", "the local PR #112's mergeability is unknown: some_new_state: GitHub answered a state " \
                             "busyyaks does not know",],
                 @port.approval_checks(@kb.card(@id), LOCAL_STEP).values_at(:state, :reason)
  end

  # with GitHub's auto-merge on, GitHub would merge on green CI without the board's approval —
  # refused, saying how to turn it off; off again → approvable
  def test_approval_refuses_a_pr_with_auto_merge_on
    row = local_gate(PR.merge("auto_merge" => { "merge_method" => "squash", "enabled_by" => { "login" => "x" } }))
    assert_equal ["blocked", "the local PR #112 has GitHub auto-merge on: GitHub would merge it on green CI without " \
                             "the board's approval — turn it off (gh pr merge --disable-auto 112 -R o/r_local)",],
                 row.values_at(:state, :reason)
    @http.pulls = [PR]
    @poller.run
    assert_equal "success", @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:state]
    # a plain project's PR names its own repo: its `pr` PR (o/r#112, assigned in setup)
    @http.pulls = [PR.merge("auto_merge" => {})]
    @conn[:projects].where(slug: "o-r").update(local_mode: nil)
    @port.approval_checks(@kb.card(@id), LOCAL_STEP)
    @poller.run
    assert_match(/turn it off \(gh pr merge --disable-auto 112 -R o\/r\)\z/,
                 @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:reason])
  end

  # a row the github service answered before it read draft / base / mergeable (before this change was deployed) is not
  # approved on what it does not hold
  def test_a_row_read_before_the_merge_fields_is_not_approved
    local_gate(PR)
    @conn[:gh_pr_checks].update(base: nil, draft: nil, merge_state: nil)
    assert_equal "the local PR #112's draft / base / mergeable state is not read yet (asked now — try again in a minute)",
                 @port.approval_checks(@kb.card(@id), LOCAL_STEP)[:reason]
  end

  def enrol!
    @conn[:projects].where(slug: "o-r").update(local_mode: "own", local_repo: "git@github.com:o/r_local.git",
                                               public_repo: "git@github.com:o/r.git", public_head: "git@github.com:o/r.git",
                                               local_base: "local", public_base: "main")
  end

  def test_public_step_needs_a_local_pr_and_says_closed_unmerged
    enrol!
    step = { from: "public_review", to: "ready", then: "merged", name: "PR approved", final: true }
    e = assert_raises(CK::Unavailable) { @port.approval_checks(@card, step) }
    assert_match(/card ##{@id} has no local PR assigned/, e.message)
    assign!("local", "https://github.com/o/r_local/pull/112")
    card = @kb.card(@id)
    assert_match(/local PR o\/r_local#112 is not read yet/, @port.approval_checks(card, step)[:reason])
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil)]
    @poller.run
    assert_equal "the local PR o/r_local#112 closed without merging (why not read yet)",
                 @port.approval_checks(card, step)[:reason]
  end

  # the local board: its first approval (Local: Human review) = the open local PR's checks; Local: Deploy check →
  # Open public PR = the local PR merged + jenkins/ci of its MERGE commit (on the working branch) green. The steps are
  # the board's own approvals (Board#approvals), not written by hand.
  def local_steps
    enrol!
    v3 = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/local_v4.board.json", __dir__)))
    @kb.board_save("o-r", v3, by: "operator")
    assign!("local", "https://github.com/o/r_local/pull/112")
    steps = CK.steps(@kb.board_of("o-r"))
    assert_equal %w[local_human_review deploy_check public_human_review], steps.map { |s| s[:from] }
    [@kb.card(@id), steps[0], steps[1]]
  end

  MERGED = PR.merge("state" => "closed", "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "m1" * 20,
                    "base" => { "ref" => "local" }).freeze

  def test_local_deploy_check_reads_the_merge_commits_ci
    card, first, deploy = local_steps
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @port.approval_checks(card, first)
    @poller.run
    assert_equal "success", @port.approval_checks(card, first)[:state], "first gate: the open local PR is green"
    assert_match(/the local PR o\/r_local#112 is still open/, @port.approval_checks(card, deploy)[:reason])
    @http.pulls = [MERGED]
    @poller.run
    assert_equal "unpolled", @port.approval_checks(card, deploy)[:state], "merged: the merge commit's CI is asked"
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    @poller.run
    assert_equal "jenkins/ci for the local PR o/r_local#112 merge is pending: merge commit m1m1m1m: running: jenkins/ci",
                 @port.approval_checks(card, deploy)[:reason]
    assert(@http.requests.any? { |u| u.include?("/repos/o/r_local/commits/#{'m1' * 20}/status?") }, "the merge commit")
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @poller.run
    assert_equal [112, "success"], @port.approval_checks(card, deploy).values_at(:number, :state)
    assert_equal "the local PR o/r_local#112 was merged before its approval", @port.approval_checks(card, first)[:reason]
  end

  # a closed-unmerged or unknown PR among several is never dropped — the final step's public PRs and a
  # plain project's `pr` PRs: only a merged one is left out; every head is said in full form (7 chars each)
  def test_a_closed_pr_among_several_blocks_the_step
    card, = local_steps
    public_step = CK.steps(@kb.board_of("o-r")).last
    assign!("public", "https://github.com/o/r/pull/5")
    assign!("public", "https://github.com/o/r/pull/6")
    card = @kb.card(@id)
    @http.pulls = [MERGED, PUB.merge("head" => { "sha" => "a" * 40 }),
                   PR.merge("number" => 6, "state" => "closed", "merged_at" => nil),]
    @http.statuses_by_sha["a" * 40] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    2.times do
      @port.approval_checks(card, public_step)
      @poller.run
    end
    assert_equal ["blocked", "the PR o/r#6 closed without merging (why not read yet)"],
                 @port.approval_checks(card, public_step).values_at(:state, :reason), "one green, one closed → refused"
    @http.pulls = [MERGED, PUB.merge("head" => { "sha" => "a" * 40 }),
                   PR.merge("number" => 6, "state" => "closed", "merged_at" => "2026-11-10T10:00:00Z"),]
    @poller.run
    assert_equal "success", @port.approval_checks(card, public_step)[:state], "a merged public PR is done: left out"
    @http.pulls = [MERGED, PUB.merge("head" => { "sha" => "a" * 40 })]
    @poller.run
    assert_equal "the PR o/r#6 was not found", @port.approval_checks(card, public_step)[:reason]
  end

  def test_a_plain_projects_pr_prs_block_on_a_closed_one_and_say_every_head
    step = { from: "human_check", to: "ready", then: "merged", name: "Approve", final: false }
    assign!("pr", "https://github.com/o/r/pull/7")
    card = @kb.card(@id)
    @http.pulls = [PR.merge("head" => { "sha" => "a" * 40 }), PR.merge("number" => 7, "head" => { "sha" => "b" * 40 })]
    @http.statuses_by_sha["a" * 40] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @http.statuses_by_sha["b" * 40] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @port.approval_checks(card, step)
    @poller.run
    green = @port.approval_checks(card, step)
    assert_equal ["success", "#{'a' * 40}+#{'b' * 40}"], green.values_at(:state, :head)
    assert_match(/ci_url https:\/\/x\/ is not the build of aaaaaaa\+bbbbbbb /,
                 @port.approval_checks(card.merge(handoff_ci_url: "https://x/"), step)[:reason], "every head, shortened")
    @http.pulls = [PR.merge("head" => { "sha" => "a" * 40 }), PR.merge("number" => 7, "state" => "closed", "merged_at" => nil)]
    @poller.run
    assert_equal ["blocked", "the PR o/r#7 closed without merging (why not read yet)"],
                 @port.approval_checks(card, step).values_at(:state, :reason)
    assert_equal "PR o/r#7 closed without merging (why not read yet)", @port.pr_checks(@kb.card(@id))[:reason],
                 "the idle watch says a closed PR too, naming its repo"
  end

  # a card that changes two repos (busyyaks + the engine it vendors) holds a local PR on each; every one
  # must be green — the first that is not is said with its repo; all green → one answer with both heads and builds
  def test_every_local_pr_of_the_step_must_be_green
    card, first, deploy = local_steps
    @conn[:projects].insert(slug: "o-eng", path: "/projects/eng", remote: "git@github.com:o/eng_local.git",
                            pr_remote: "git@github.com:o/eng_local.git", own: true, commits_window: 0, mine_window: 0,
                            dirty: 0, scanned_at: 0, local_mode: "own", local_repo: "git@github.com:o/eng_local.git",
                            public_repo: "git@github.com:o/eng.git", public_head: "git@github.com:o/eng.git",
                            local_base: "local", public_base: "main")
    assign!("local", "https://github.com/o/eng_local/pull/91")
    card = @kb.card(@id)
    engine = PR.merge("number" => 91, "head" => { "sha" => "def" })
    eng_ci = "https://ci.example.com/job/eng/7/"
    @http.pulls = [PR, engine]
    @http.statuses_by_sha["abc"] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @http.statuses_by_sha["def"] = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    @port.approval_checks(card, first)
    @poller.run
    assert_equal ["pending", "o/eng_local PR #91: CI is still running"],
                 @port.approval_checks(card, first).values_at(:state, :reason)
    @http.statuses_by_sha["def"] = [{ "state" => "success", "updated_at" => finish_at(@now), "target_url" => eng_ci }]
    @poller.run
    green = @port.approval_checks(card, first)
    assert_equal ["success", "abc+def", [CI_URL, eng_ci]], green.values_at(:state, :head, :builds)
    assert_equal "success", @port.approval_checks(card.merge(handoff_ci_url: eng_ci), first)[:state],
                 "a handoff's ci_url may be the build of any of the PRs' heads"
    assert_match(/ci_url https:\/\/ci.example.com\/x\/ is not the build of abc\+def/,
                 @port.approval_checks(card.merge(handoff_ci_url: "https://ci.example.com/x/"), first)[:reason])
    @http.pulls = [MERGED, engine]
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    2.times do # the merges are read, then the merge commit's CI is asked
      @port.approval_checks(card, deploy)
      @poller.run
    end
    assert_equal "the local PR o/eng_local#91 is still open, not merged into the local repo",
                 @port.approval_checks(card, deploy)[:reason], "the deploy step needs every local PR merged"
    assert_equal "the local PR o/r_local#112 was merged before its approval", @port.approval_checks(card, first)[:reason]
    # both merged, both merge commits green → the deploy step passes
    @http.pulls = [MERGED, engine.merge("state" => "closed", "merged_at" => "2026-11-09T11:00:00Z",
                                        "merge_commit_sha" => "m2" * 20, "base" => { "ref" => "local" }),]
    @http.statuses_by_sha["m2" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    2.times do
      @port.approval_checks(card, deploy)
      @poller.run
    end
    assert_equal "success", @port.approval_checks(card, deploy)[:state], "every local PR merged, every merge CI green"
  end

  # a local PR on another enrolled project's repo (the engine the card vendors) is based on THAT
  # project's working branch, never the card's own project's; a repo no enrolment names refuses, never any base
  def test_a_local_pr_on_another_projects_repo_is_based_on_that_projects_branch
    card, first, = local_steps
    @conn[:projects].insert(slug: "o-eng", path: "/projects/eng", remote: "git@github.com:o/eng_local.git",
                            pr_remote: "git@github.com:o/eng_local.git", own: true, commits_window: 0, mine_window: 0,
                            dirty: 0, scanned_at: 0, local_mode: "own", local_repo: "git@github.com:o/eng_local.git",
                            public_repo: "git@github.com:o/eng.git", public_head: "git@github.com:o/eng.git",
                            local_base: "main", public_base: "main")
    assign!("local", "https://github.com/o/eng_local/pull/91")
    card = @kb.card(@id)
    @http.pulls = [PR, PR.merge("number" => 91, "head" => { "sha" => "def" }, "base" => { "ref" => "local" })]
    @http.statuses_by_sha["abc"] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @http.statuses_by_sha["def"] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @port.approval_checks(card, first)
    @poller.run
    assert_equal ["blocked", "o/eng_local the local PR #91 is based on local, not main"],
                 @port.approval_checks(card, first).values_at(:state, :reason),
                 "the engine PR on the card's own project's base is refused: its own project works on main"
    @http.pulls = [PR, PR.merge("number" => 91, "head" => { "sha" => "def" }, "base" => { "ref" => "main" })]
    @poller.run
    assert_equal ["success", "abc+def"], @port.approval_checks(card, first).values_at(:state, :head)
    @conn[:projects].where(slug: "o-eng").update(local_base: nil, local_error: "guard.localBranch is not set")
    e = assert_raises(CK::Unavailable) { @port.approval_checks(card, first) }
    assert_equal "card ##{@id}: the local PR o/eng_local's base branch is not known: guard.localBranch is not set",
                 e.message
    @conn[:projects].where(slug: "o-eng").delete
    e = assert_raises(CK::Unavailable) { @port.approval_checks(card, first) }
    assert_equal "card ##{@id}: the local PR o/eng_local's base branch is not known: o/eng_local is the local repo " \
                 "of no enrolled project", e.message
  end

  # a card approved with needs rebase whose PR then MERGED (the agent merged before a watch
  # pass cleared the mark) is answered with the merge commit's CI — never "no PR", which would hold it for good; an
  # unmarked card's merged PR is answered as before (nil = no open PR)
  def test_a_marked_card_whose_pr_merged_is_answered_by_its_merge_commit
    enrol!
    @conn[:projects].where(slug: "o-r").update(local_mode: nil)
    assign!("pr", "https://github.com/o/r/pull/112") # a plain project's PR is on its own repo
    @http.pulls = [MERGED]
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    card = @kb.card(@id)
    marked = card.merge(needs_rebase: { "base" => "local", "base_sha" => "b0" * 20, "state" => "conflicts" })
    @port.approval_checks(card, LOCAL_STEP)
    @poller.run
    assert_nil @port.approval_checks(card, LOCAL_STEP), "unmarked: a merged PR is no open PR, as before"
    assert_equal "unpolled", @port.approval_checks(marked, LOCAL_STEP)[:state], "marked: its merge commit's CI is asked"
    @poller.run
    assert_equal "pending", @port.approval_checks(marked, LOCAL_STEP)[:state]
    assert_match(%r{\ACI for the PR o/r#112 merge is pending: merge commit m1m1m1m},
                 @port.approval_checks(marked, LOCAL_STEP)[:reason])
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @poller.run
    assert_equal [112, "success"], @port.approval_checks(marked, LOCAL_STEP).values_at(:number, :state)
  end

  # the public final step: a marked card whose public PR merged is answered by that merge's CI on
  # the public repo; unmarked → the merged public PR is no open PR, as before
  def test_a_marked_card_whose_public_pr_merged_is_answered_by_its_merge_commit
    enrol!
    assign!("local", "https://github.com/o/r_local/pull/112")
    assign!("public", "https://github.com/o/r/pull/5")
    merged_pub = PUB.merge("state" => "closed", "merged_at" => "2026-11-09T11:00:00Z", "merge_commit_sha" => "p5" * 20)
    @http.pulls = [merged_pub, MERGED]
    @http.statuses_by_sha["p5" * 20] = [{ "state" => "failure", "updated_at" => finish_at(@now) }]
    card = @kb.card(@id)
    marked = card.merge(needs_rebase: { "base" => "main", "base_sha" => "b0" * 20, "state" => "conflicts" })
    3.times do # the local merge, the public PR, then its merge commit's CI
      @port.approval_checks(marked, PUBLIC_STEP)
      @poller.run
    end
    assert_nil @port.approval_checks(card, PUBLIC_STEP), "unmarked: a merged public PR is no open PR, as before"
    red = @port.approval_checks(marked, PUBLIC_STEP)
    assert_equal ["failure", 5], red.values_at(:state, :number)
    assert_match(%r{\ACI for the public PR o/r#5 merge is failure: merge commit p5p5p5p}, red[:reason])
    assert(@http.requests.any? { |u| u.include?("/repos/o/r/commits/#{'p5' * 20}/status?") }, "on the public repo")
    @http.statuses_by_sha["p5" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @poller.run
    assert_equal [5, "success"], @port.approval_checks(marked, PUBLIC_STEP).values_at(:number, :state)
  end

  # Jenkins coalesces the working branch's builds: a merge commit with no checks of its own passes on the branch HEAD's
  # green jenkins/ci only when that head CONTAINS it (compare: ahead / identical); otherwise refused naming both shas.
  def test_a_coalesced_merge_commit_passes_on_a_green_head_that_contains_it
    card, _first, deploy = local_steps
    @http.pulls = [MERGED]
    @http.statuses_by_sha["m1" * 20] = []
    @http.heads["local"] = "h2" * 20
    @http.statuses_by_sha["h2" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @http.compare = "diverged"
    2.times do # the local PR's merge is read first, then its merge commit's CI is asked
      @port.approval_checks(card, deploy)
      @poller.run
    end
    assert_equal "jenkins/ci for the local PR o/r_local#112 merge is nochecks: merge commit m1m1m1m has no checks and local " \
                 "head h2h2h2h does not contain it (compare: diverged)", @port.approval_checks(card, deploy)[:reason]
    @http.compare = "ahead"
    @poller.run
    assert_equal [112, "success"], @port.approval_checks(card, deploy).values_at(:number, :state)
    assert_equal "merge commit m1m1m1m has no checks of its own; read local head h2h2h2h, which contains it: " \
                 "passed: jenkins/ci",
                 @conn[:gh_pr_checks].where(ref: "merge:112").get(:detail)
    assert(@http.requests.any? { |u| u.end_with?("/repos/o/r_local/compare/#{'m1' * 20}...#{'h2' * 20}") })
    @http.statuses_by_sha["h2" * 20] = [{ "state" => "failure", "updated_at" => finish_at(@now) }]
    @poller.run
    red = @port.approval_checks(card, deploy)
    assert_match(/merge is failure: merge commit m1m1m1m has no checks of its own; read local head h2h2h2h/, red[:reason])
    assert_equal "failure", red[:state], "red stays red (the gate watch pings the owner on state failure)"
    @http.heads["local"] = "m1" * 20 # the merge commit is the head and has no checks yet
    @poller.run
    assert_match(/merge is nochecks: merge commit m1m1m1m \(the head of local\) has no checks/,
                 @port.approval_checks(card, deploy)[:reason])
  end

  # approved, merged, deployed, then moved back into the first gate — the merged local PR is not "merged
  # before its approval" when an approve of the first step follows the newest handoff into it: the merge commit's CI
  # answers instead
  def test_the_first_gate_passes_a_merged_pr_approved_after_its_handoff
    card, first, = local_steps
    @http.pulls = [MERGED]
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @port.approval_checks(card, first)
    @poller.run
    assert_equal "the local PR o/r_local#112 was merged before its approval", @port.approval_checks(card, first)[:reason],
                 "no handoff, no approval: refused"
    handoff = ->(n) { "handed to Local: Human review: PR https://github.com/o/r_local/pull/#{n} · CI https://ci.example.com/1" }
    log = ->(kind, body) { @conn[:card_activity].insert(card_id: @id, kind: kind, author: "x", created_at: @now, body: body) }
    log.call("approve", "approved Local: Human review → Local: Merged")
    log.call("handoff", handoff.call(112))
    assert_equal "the local PR o/r_local#112 was merged before its approval", @port.approval_checks(card, first)[:reason],
                 "an approve older than the handoff of this PR approved nothing of it"
    log.call("approve", "approved Local: Human review → Local: Merged")
    log.call("handoff", "handed to Local: Deploy check: PR https://github.com/o/r_local/pull/112") # the deploy receipt
    log.call("approve", "approved Local: Deploy check → Public: Create PR") # another gate's approval approves nothing here
    2.times do # the merge commit's CI is asked, then read
      @port.approval_checks(card, first)
      @poller.run
    end
    assert_equal [112, "success"], @port.approval_checks(card, first).values_at(:number, :state),
                 "a later handoff into another gate does not hide the first step's approval"
    log.call("handoff", handoff.call(112))
    assert_equal "the local PR o/r_local#112 was merged before its approval", @port.approval_checks(card, first)[:reason],
                 "a new handoff into the first gate asks for a new approval"
    log.call("approve", "approved Local: Deploy check → Public: Create PR")
    assert_equal "the local PR o/r_local#112 was merged before its approval", @port.approval_checks(card, first)[:reason],
                 "only an approve of the first step counts"
  end

  def test_the_first_gate_says_closed_without_merging
    card, first, = local_steps
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil)]
    @port.approval_checks(card, first)
    @poller.run
    assert_equal "the local PR o/r_local#112 closed without merging (why not read yet)",
                 @port.approval_checks(card, first)[:reason]
    @http.events = [{ "event" => "head_ref_deleted" }, { "event" => "closed", "actor" => { "login" => "robertziel" } }]
    @states.run
    assert_equal "the local PR o/r_local#112 closed without merging (head deleted)",
                 @port.approval_checks(card, first)[:reason]
  end

  # the local PR is the assigned one — never a PR in pr_url or in a handoff's text
  def test_the_local_pr_is_never_read_from_pr_url_or_handoffs
    enrol!
    step = { from: "public_human_review", to: "awaiting_merge", then: "done", name: "Approve", final: true }
    @conn[:card_activity].insert(card_id: @id, kind: "handoff", author: "reviewer", created_at: @now,
                                 body: "handed to Local: Human review: PR https://github.com/o/r_local/pull/112 · CI https://ci.example.com/1")
    @conn[:cards].where(id: @id).update(pr_url: "https://github.com/o/r_local/pull/112")
    e = assert_raises(CK::Unavailable) { @port.approval_checks(@kb.card(@id), step) }
    assert_equal "card ##{@id} has no local PR assigned (kanban_pr_assign role local)", e.message
    assert_equal 0, @conn[:gh_pr_checks].count
  end

  # a request the github service stopped polling (older than wanted_for) is asked afresh — not
  # reported as "service stopped"; inside the window an old answer still is.
  def test_a_request_outside_the_poll_window_is_asked_again
    card = @card
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

  # the github service's last poll of a request lands seconds before the request leaves the window; the
  # handoff right after it uses that green read at once (first try) — never drops it and refuses "CI not read yet"
  def test_a_fresh_green_read_is_used_although_its_request_left_the_window
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    asked = @now
    e = assert_raises(AgentsKanban::Invalid) { hand_off(CI_URL) }
    assert_match(/CI not read yet/, e.message, "nothing read yet: refused")
    @now = asked + 595
    @poller.run # the last poll inside the window (requested_at >= now - 600)
    @now = asked + 608 # 608 s after the request, 13 s after the read
    hand_off(CI_URL)
    assert_equal [@kb.board_of("o-r").approvals.first.from, CI_URL], @kb.card(@id).values_at(:column, :ci_url)
    assert_equal [@now, asked + 595, "success"],
                 @conn[:gh_pr_checks].where(ref: "pr:112").get(%i[requested_at checked_at state]),
                 "the read is kept and the request renewed"
  end

  # a green read for an older head is still refused at the handoff (its ci_url names the new head's build),
  # and the request stays registered, so the service reads the new head
  def test_a_fresh_green_for_another_head_is_refused_and_asked_again
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    asked = @now
    @port.pr_checks(@card)
    @now = asked + 595
    @poller.run
    @now = asked + 608
    e = assert_raises(AgentsKanban::Invalid) { hand_off("https://ci.example.com/job/r/2/") }
    assert_match(%r{ci_url https://ci.example.com/job/r/2/ is not the build of abc}, e.message)
    assert_equal ["doing", nil], @kb.card(@id).values_at(:column, :handoff_at)
    assert_equal @now, @conn[:gh_pr_checks].where(ref: "pr:112").get(:requested_at), "asked again"
  end

  # past the window an answer older than stale_after (or a failed read) is not used: refused "CI not read
  # yet" and asked afresh (requested now, the old read dropped); the next poll answers and the retry passes
  def test_a_stale_read_past_the_window_is_refused_and_asked_again
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    asked = @now
    @port.pr_checks(@card)
    @poller.run
    @now = asked + 601 # read 601 s ago > stale_after 180
    e = assert_raises(AgentsKanban::Invalid) { hand_off(CI_URL) }
    assert_match(/CI not read yet \(asked now/, e.message)
    assert_equal [@now, nil], @conn[:gh_pr_checks].where(ref: "pr:112").get(%i[requested_at checked_at])
    @conn[:gh_pr_checks].where(ref: "pr:112").update(requested_at: asked, checked_at: @now - 5, error: "boom")
    assert_equal "unpolled", @port.pr_checks(@card)[:state], "a failed read past the window is asked afresh too"
    assert_equal [@now, nil, nil], @conn[:gh_pr_checks].where(ref: "pr:112").get(%i[requested_at checked_at error])
    @poller.run
    hand_off(CI_URL)
    assert_equal CI_URL, @kb.card(@id)[:ci_url]
  end

  # a request the service has not answered yet is refused, inside the window too
  def test_an_unread_request_is_refused
    @port.pr_checks(@card)
    @now += 30
    e = assert_raises(AgentsKanban::Invalid) { hand_off(CI_URL) }
    assert_match(/CI not read yet/, e.message)
    assert_equal "doing", @kb.card(@id)[:column]
  end

  def hand_off(ci_url)
    @kb.handoff(@id, qa: "open the board and check the card moves", pr_url: "https://github.com/o/r/pull/112",
                     ci_url: ci_url, ui_change: false, by: "lead")
  end

  # end to end on a local (v3) board: the Store refuses the final approval (Public: Human review → Awaiting merge)
  # while the local PR is open, then while the card records no public PR, then on the public PR's CI; a failed or stale
  # read is refused as unknown, never guessed.
  def test_the_store_gates_the_public_step_on_the_local_merge_and_the_public_ci
    enrol!
    v3 = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/local_v4.board.json", __dir__)))
    @kb.board_save("o-r", v3, by: "operator")
    assign!("local", "https://github.com/o/r_local/pull/112")
    @conn[:cards].where(id: @id).update(column: "public_human_review")
    refuse = lambda do |pattern, drag: false| # drag: the step's own transition (a plain drag is never refused)
      e = assert_raises(AgentsKanban::Invalid) do
        # the step's named transition asks CI like the button; a plain drag never does
        drag ? @kb.move(@id, transition: "Approve", by: "operator") : @kb.approve(@id, by: "operator")
      end
      assert_match(pattern, e.message)
      assert_equal ["public_human_review", nil], @kb.card(@id).values_at(:column, :approved_at)
    end
    unread = "the local PR o/r_local#112 is not read yet (asked now — try again in a minute)" # an approval or a handoff
    drag_way = "A drag into Awaiting merge approves without asking CI"
    refuse.call(/Public: Human review → Awaiting merge\): card ##{@id} — #{Regexp.escape("#{unread}. #{drag_way}")}\z/)
    @http.pulls = [PR]
    @poller.run
    refuse.call(/the local PR o\/r_local#112 is still open/, drag: true)
    @http.pulls = [PUB, PR.merge("state" => "closed", "merged_at" => "2026-11-09T10:00:00Z")]
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    @poller.run
    none = "card ##{@id} has no public PR assigned (kanban_pr_assign role public)"
    refuse.call(/CI state of card ##{@id} is unknown — #{Regexp.escape("#{none}. #{drag_way}")}\z/)
    assign!("public", "https://github.com/o/r/pull/5")
    refuse.call(/its PR of card ##{@id} — CI not read yet/)
    # the watch pass and the waiting counts hand the port RAW rows (metadata = its JSON text)
    _, state, = @kb.approval_prefetch_pass.find { |id, *| id == @id }
    assert_equal "unpolled", state, "the raw row's prs.public is read, not \"no public PR assigned\""
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

  # the notifier's watch pass keeps every gated card's approval checks asked (the engine's approval
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

  # the compose cadences: a watch pass every 30 s (notifier_watch_seconds), a poll every 60 s (github_ci_interval_seconds)
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

  # the CI poller's cache key names its KEEP set too: an entry written with another set is another key, never read
  def test_the_ci_cache_key_names_its_field_set
    url = "/repos/o/r/pulls/112"
    key = CK::Poller.cache_key(url)
    assert key.start_with?("ci:") && key.end_with?(":#{url}")
    refute_equal key, Busyyaks::GithubNetwork.cache_key("ci:", CK::Poller::KEEP - ["merged_at"], url)
    refute_equal key, "ci:#{url}", "the key before field sets were named"
  end

  # the poller's ETag cache keeps only the fields it reads, and forgets a URL nobody read for the poll window
  def test_the_etag_cache_is_slim_and_pruned
    @http.pulls = [PR.merge("body" => "x" * 10_000, "head" => { "sha" => "abc", "repo" => { "big" => "y" * 10_000 } })]
    at = finish_at(@now)
    @http.statuses = [{ "state" => "success", "updated_at" => at, "description" => "z" * 10_000 }]
    handoff!
    run_services_for(120)
    pages = -> { @conn[:gh_pages].where(Sequel.like(:url, "ci:%")).order(:url).select_map(%i[url items]) }
    urls = ["/repos/o/r/commits/abc/check-runs?per_page=100&page=1",
            "/repos/o/r/commits/abc/status?per_page=100&page=1", "/repos/o/r/pulls/112",]
    assert_equal urls.map { |u| CK::Poller.cache_key(u) }.sort, pages.call.map(&:first)
    # every page = exactly the fields the poller reads: no PR body, no repo, no status description
    assert_equal [{ "check_runs" => [], "total_count" => 0 },
                  { "statuses" => [{ "state" => "success", "updated_at" => at, "context" => "jenkins/ci",
                                     "created_at" => at, "target_url" => CI_URL, }], "total_count" => 1, },
                  { "number" => 112, "state" => "open", "head" => { "sha" => "abc" }, "base" => { "ref" => "local" },
                    "draft" => false, "mergeable" => true, "mergeable_state" => "clean", },],
                 pages.call.map { |_, i| JSON.parse(i) }
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
    v3 = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/local_v4.board.json", __dir__)))
    @kb.board_save("o-r", v3, by: "operator")
    @conn[:cards].where(id: @id).update(column: "local_agent_review")
    assign!("local", "https://github.com/o/r_local/pull/112")
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
    assert_equal "not approved (Local: Human review → Local: Merged): card ##{@id} — #{moved}; hand it back for review. " \
                 "A drag into Local: Merged approves without asking CI", e.message
    assert_equal "local_human_review", @kb.card(@id)[:column]
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

  # Every PR assigned to a live card is watched on the notifier's watch pass — never only while somebody
  # has the card open — and a close without merging is told once on the card and to its owner, with the reason
  def test_a_closed_unmerged_pr_alarms_the_card_and_pings_the_owner_once
    @http.pulls = [PR]
    log = StringIO.new
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: log)
    n.watch # the watch pass asks for the PR's state: nobody opened the card
    assert_equal [["o/r", "pr:112"]], @conn[:gh_pr_states].select_map(%i[repo ref])
    @states.run
    n.watch
    n.deliver
    assert_empty @launcher.sent, "an open PR alarms nobody"
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil)]
    @http.events = [{ "event" => "base_ref_deleted" }, { "event" => "closed", "actor" => { "login" => "robertziel" } }]
    @now += 60
    @states.run
    n.watch
    n.deliver
    assert_equal 1, @launcher.sent.size, log.string
    assert_match(/PR o\/r#112 \(pr\) closed without merging \(base deleted\) while card ##{@id} "ship" is in In progress/,
                 @launcher.sent.first[1])
    said = @kb.activity(@id).select { |a| a[:kind] == "comment" }.map { |a| a[:body] }
    assert_equal ["PR o/r#112 (pr) closed without merging (base deleted) — pinged shop."], said
    3.times do
      @now += 60
      @states.run
      n.watch
      n.deliver
    end
    assert_equal 1, @launcher.sent.size, "one ping per close"
    assert_match(/pr watch: card #{@id} PR closed without merging, owner pinged/, log.string)
  end

  # a failed read of the close's reason tells nothing yet and is said as the PR's error; the close is told once, with
  # its reason, when the next poll reads it — never an "unknown" pinned on the alarm by a transient failure
  def test_a_close_whose_reason_read_fails_is_said_as_an_error_then_told_once_with_the_reason
    log = StringIO.new
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: log)
    n.watch
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil)]
    @http.events = :fail
    @states.run
    n.watch
    n.deliver
    assert_empty @launcher.sent
    assert_match(/pr watch: card #{@id}: pr PR #112 on o\/r: GitHub read failed: GitHub 500/, log.string)
    @http.events = [{ "event" => "head_ref_deleted" }, { "event" => "closed", "actor" => { "login" => "ann" } }]
    3.times do
      @now += 60
      @states.run
      n.watch
      n.deliver
    end
    assert_equal 1, @launcher.sent.size, log.string
    assert_match(/PR o\/r#112 \(pr\) closed without merging \(head deleted\)/, @launcher.sent.first[1])
    assert_equal 1, @kb.activity(@id).count { |a| a[:kind] == "comment" }
  end

  # a close GitHub gave no closed_at is never told under a made-up key: said as the PR's error on every pass
  def test_a_close_with_no_closed_at_is_said_never_told
    @kb.pr_watch_pass
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil, "closed_at" => nil)]
    @states.run
    assert_equal [[@id, "unavailable: pr PR #112 on o/r: closed, GitHub gave o/r#112 no closed_at"]], @kb.pr_watch_pass
    assert_empty @kb.activity(@id).select { |a| a[:kind] == "comment" }
    assert_empty @kb.pings(@id)
  end

  # a row polled as closed before closed_at / reason existed (an upgrade) is not told until the poller re-reads it —
  # then once, with the reason: never "()" first and the real close again after
  def test_a_closed_row_polled_before_the_upgrade_is_told_once_after_its_re_read
    @conn[:gh_pr_states].insert(repo: "o/r", ref: "pr:112", number: 112, state: "closed", checked_at: @now,
                                requested_at: @now)
    assert_equal [], @kb.pr_watch_pass, "no reason read yet: nothing told"
    @http.pulls = [PR.merge("state" => "closed", "merged_at" => nil)]
    @http.events = [{ "event" => "closed", "actor" => { "login" => "ann" } }]
    @now += 60
    @states.run
    assert_equal [[@id, :closed]], @kb.pr_watch_pass
    @now += 60
    @states.run
    assert_equal [], @kb.pr_watch_pass
    said = @kb.activity(@id).select { |a| a[:kind] == "comment" }.map { |a| a[:body] }
    assert_equal ["PR o/r#112 (pr) closed without merging (by ann) — pinged shop."], said
  end

  def test_a_card_in_a_terminal_column_is_not_watched
    b = @kb.board_of("o-r")
    refute_empty b.terminal
    b.terminal.each do |col|
      @conn[:cards].where(id: @id).update(column: col)
      assert_equal [], @kb.pr_watch_pass
    end
    assert_empty @conn[:gh_pr_states].all
  end

  def test_the_pr_watch_reads_both_sides_of_an_enrolled_card_and_says_a_failed_read
    @conn[:cards].where(id: @id).update(metadata: nil) # the setup's `pr` PR is no enrolled card's
    enrol!
    assign!("local", "https://github.com/o/r_local/pull/112")
    assign!("public", "https://github.com/o/r/pull/43")
    @kb.pr_watch_pass
    assert_equal [["o/r", "pr:43"], ["o/r_local", "pr:112"]], @conn[:gh_pr_states].order(:repo).select_map(%i[repo ref])
    @http.pulls = [PR.merge("number" => 43, "state" => "closed", "merged_at" => nil)] # 112: 404 on o/r_local
    @states.run
    local_down = %r{\Aunavailable: local PR #112 on o/r_local: GitHub read failed: .*404}
    pass = @kb.pr_watch_pass
    assert_equal 2, pass.size
    assert_includes pass, [@id, :closed], "the closed public PR is told although the local read failed"
    assert_match local_down, pass.first[1], "one entry per assigned PR, in the card's order (local, public)"
    # the close is told already; the local PR's failed read is still said on the next pass — never hidden by it
    @now += 60
    @states.run
    pass = @kb.pr_watch_pass
    assert_equal 1, pass.size
    assert_match local_down, pass.first[1]
    @http.pulls = []
    @now += 60
    @states.run
    pass = @kb.pr_watch_pass
    assert_equal 2, pass.size, "both reads failed: both said"
    assert_match local_down, pass.first[1]
    assert_match(%r{\Aunavailable: public PR #43 on o/r: GitHub read failed}, pass.last[1])
  end

  def test_a_bad_assignment_is_said_by_the_pr_watch
    # metadata prs is written only by kanban_pr_assign: a bad entry can only come from a raw write
    @conn[:cards].where(id: @id).update(metadata: JSON.generate("prs" => [{ "url" => "https://example.com/x",
"role" => "pr", }]))
    assert_match(/\Aunavailable: card ##{@id} metadata prs has an entry that is no PR URL/,
                 @kb.pr_watch_pass.first[1])
  end

  # a gate card whose PR closed is told what happened — never the generic "no PR whose checks could be read" — and its
  # owner is pinged by the PR watch
  def test_gate_card_whose_pr_closed_is_told_not_silent
    enrol!
    v3 = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/local_v4.board.json", __dir__)))
    @kb.board_save("o-r", v3, by: "operator")
    assign!("local", "https://github.com/o/r_local/pull/112")
    assign!("public", "https://github.com/o/r/pull/43")
    @conn[:cards].where(id: @id).update(column: "public_human_review")
    @http.pulls = [MERGED, PR.merge("number" => 43, "state" => "closed", "merged_at" => nil)]
    @http.events = [{ "event" => "base_ref_deleted" }, { "event" => "closed", "actor" => { "login" => "robertziel" } }]
    log = StringIO.new
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: log)
    2.times do # the local PR's merge is read first, then the public PR's checks are asked
      n.watch
      @poller.run
      @states.run
    end
    n.watch
    n.deliver
    hold = "the PR o/r#43 closed without merging (base deleted)"
    assert_equal hold, @kb.card(@id)[:gate_hold]
    e = assert_raises(AgentsKanban::Invalid) { @kb.approve(@id, by: "operator") }
    assert_match(/card ##{@id} — #{Regexp.escape(hold)}/, e.message)
    assert_equal 1, @launcher.sent.size, log.string
    assert_match(/PR o\/r#43 \(public\) closed without merging \(base deleted\)/, @launcher.sent.first[1])
  end

  def test_the_board_config_is_wired
    assert_equal({ ci_ping_after_minutes: 10, ci_comment_after_minutes: 20, owner_idle_hours: 4 },
                 Busyyaks::Kanban.config.idle_watch.to_h)
  end

  # ── card #470: CI read correctness ──

  # one row the poller cannot read — GitHub's error or any other (a body of a shape it does not expect) — is stored on
  # that row; the rows after it are still answered
  def test_one_bad_row_does_not_abort_the_ci_batch
    @http.pulls = [PR, { "number" => 113, "state" => "open", "head" => "not a mapping" }]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @conn[:gh_pr_checks].insert(repo: "o/r", ref: "pr:113", requested_at: @now) # first: it fails before 112 is read
    @conn[:gh_pr_checks].insert(repo: "o/r", ref: "pr:114", requested_at: @now) # GitHub: no such PR → "none"
    @conn[:gh_pr_checks].insert(repo: "o/r", ref: "pr:112", requested_at: @now)
    assert_equal 3, @poller.run
    rows = @conn[:gh_pr_checks].to_hash(:ref)
    assert_match(/\ATypeError: /, rows["pr:113"][:error])
    assert_nil rows["pr:113"][:checked_at]
    assert_equal %w[none success], [rows["pr:114"][:state], rows["pr:112"][:state]]
    assert_equal [nil, nil], [rows["pr:114"][:error], rows["pr:112"][:error]]
    assign!("pr", "https://github.com/o/r/pull/113")
    e = assert_raises(CK::Unavailable) { @port.pr_checks(@kb.card(@id)) }
    assert_match(%r{\AGitHub check poll for o/r pr:113 failed: TypeError: }, e.message)
  end

  # every page of a check list GitHub counts is read; a list it counts but does not hand over whole is refused, never
  # taken for green
  def test_check_runs_beyond_one_page_are_read_or_refused
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @http.runs = Array.new(150) do |i|
      { "name" => i == 149 ? "jenkins/ci" : "lint-#{i}", "status" => "completed",
        "conclusion" => i == 149 ? "failure" : "success", "completed_at" => finish_at(@now), }
    end
    @port.pr_checks(@card)
    @poller.run
    assert_equal "failure", @port.pr_checks(@card)[:state], "the required run on page 2 was read"
    assert(@http.requests.any? { |u| u.end_with?("/check-runs?per_page=100&page=2") })
    @http.short_by = 1 # GitHub counts one more than it hands over
    @now += 60
    @poller.run
    e = assert_raises(CK::Unavailable) { @port.pr_checks(@card) }
    assert_match(/GitHub counts 2 statuses but 1 were read \(page 1 was short\)/, e.message)
  end

  # a REQUIRED check pending longer than ci.max_pending_minutes is stuck: the gate says so with the context and the
  # time, and the owner is pinged once for that build (finished_at = the moment it became stuck)
  def test_a_check_pending_too_long_is_stuck
    @http.pulls = [PR]
    started = @now - 3540 # 59 min ago
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(started) }]
    @port.pr_checks(@card)
    @poller.run
    assert_equal "pending", @port.pr_checks(@card)[:state]
    @now += 120 # 61 min
    @poller.run
    got = @port.pr_checks(@card)
    assert_equal ["stuck", started + 3600], got.values_at(:state, :finished_at)
    assert_equal "PR #112: CI stuck — jenkins/ci pending since #{finish_at(started)}, over ci.max_pending_minutes 60",
                 got[:reason]
    @http.statuses = [{ "context" => "slow-docs", "state" => "pending", "updated_at" => finish_at(started) },
                      { "state" => "success", "updated_at" => finish_at(@now) },]
    @now += 60
    @poller.run
    assert_equal "success", @port.pr_checks(@card)[:state], "an informational check is never stuck"

    # in a gate: held, and one ping to the owner for the stuck build
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    handoff!
    @http.statuses = [{ "state" => "pending", "updated_at" => finish_at(@now) }]
    run_services_for(3600 + 300)
    pings = @conn[:card_pings].where(card_id: @id, reason: "gate_red").all
    assert_equal 1, pings.size
    assert_match(/PR #112: CI stuck — jenkins\/ci pending since .* while card ##{@id} "ship" waits in Human Check/,
                 pings[0][:text])
    e = assert_raises(AgentsKanban::Invalid) { @kb.approve(@id, by: "operator") }
    assert_match(/CI stuck — jenkins\/ci pending since/, e.message)
  end

  # only the contexts config ci.required lists for the repo gate; every other check is informational (named when it
  # fails); a required one that has not reported is not green; a repo the config does not list is refused, never guessed
  def test_only_required_contexts_gate
    @http.pulls = [PR]
    @port.pr_checks(@card)
    check = lambda do |statuses, runs = []|
      @http.statuses = statuses
      @http.runs = runs
      @now += 60
      @poller.run
      @port.pr_checks(@card).values_at(:state, :detail)
    end
    ok = { "state" => "success", "updated_at" => finish_at(@now) }
    red = { "state" => "failure", "updated_at" => finish_at(@now) }
    lint = { "name" => "lint", "status" => "completed", "conclusion" => "failure", "completed_at" => finish_at(@now) }
    assert_equal ["success", "passed: jenkins/ci; informational, failing: codecov, lint"],
                 check.call([ok, red.merge("context" => "codecov")], [lint])
    assert_equal ["failure", "failed: jenkins/ci"], check.call([red, ok.merge("context" => "codecov")])
    assert_equal ["nochecks", "required jenkins/ci not reported on abc; informational, failing: lint"],
                 check.call([ok.merge("context" => "codecov")], [lint])
    @http.pulls << PR.merge("number" => 1)
    @conn[:gh_pr_checks].insert(repo: "o/other", ref: "pr:1", requested_at: @now)
    @poller.run
    assert_equal "no required CI contexts for o/other: config/busyyaks.yml ci.required does not list it",
                 @conn[:gh_pr_checks].where(repo: "o/other").get(:error)
  end

  # the handoff's ci_url must be the build of the head it hands over (a required check's target_url / details_url on
  # it): an older build or a URL naming no build is refused AT THE HANDOFF. A rebuild of the same head afterwards never
  # parks the card: the Approve asks only whether the head's required checks are green
  def test_handoff_ci_url_must_be_the_heads_build
    @http.pulls = [PR]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    @port.pr_checks(@card)
    @poller.run
    hand = lambda do |url|
      @kb.handoff(@id, qa: "open the board and check the card moves", pr_url: "https://github.com/o/r/pull/112",
                       ci_url: url, ui_change: false, by: "lead")
    end
    e = assert_raises(AgentsKanban::Invalid) { hand.call("https://ci.example.com/job/r/0/") }
    assert_match(%r{ci_url https://ci.example.com/job/r/0/ is not the build of abc \(#{CI_URL}\) — hand off with the head's},
                 e.message)
    assert_equal ["doing", nil], @kb.card(@id).values_at(:column, :ci_url), "nothing written"
    hand.call(CI_URL)
    assert_equal [CI_URL, nil], [@kb.card(@id)[:ci_url], @kb.card(@id)[:approved_by]]
    rerun = "https://ci.example.com/job/r/2/"
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now), "target_url" => rerun }]
    @now += 60
    @poller.run
    assert_nil @kb.gate_hold(@kb.card(@id), @kb.board_of("o-r")), "approvable now: the head is green"
    @kb.approve(@id, by: "operator")
    assert_equal "operator", @kb.card(@id)[:approved_by]
  end

  # Local: Deploy check: the handoff's ci_url is the build of the merge commit on the working branch (jenkins/ci on
  # local, e.g. .../job/local/23/) — or, when Jenkins coalesced it, of the branch head that contains it
  def test_a_deploy_check_handoff_passes_with_the_merge_commits_build
    card, _first, deploy = local_steps
    build = "https://jenkins.example.com/job/busyyaks/job/local/23/"
    @http.pulls = [MERGED]
    @http.statuses_by_sha["m1" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now), "target_url" => build }]
    2.times do # the local PR's state, then its merge commit's CI
      @port.approval_checks(card, deploy)
      @poller.run
    end
    handing = ->(url) { @port.approval_checks(card.merge(handoff_ci_url: url), deploy) }
    assert_equal [112, "success"], handing.call(build).values_at(:number, :state)
    assert_match(%r{ci_url .*/local/22/ is not the build of the commit read \(#{build}\)},
                 handing.call(build.sub("23", "22"))[:reason])
    assert_equal "success", handing.call(nil)[:state], "no ci_url handed over: nothing to compare"

    head = "https://jenkins.example.com/job/busyyaks/job/local/24/" # coalesced: the merge commit has no checks
    @http.statuses_by_sha["m1" * 20] = []
    @http.heads["local"] = "h2" * 20
    @http.compare = "ahead"
    @http.statuses_by_sha["h2" * 20] = [{ "state" => "success", "updated_at" => finish_at(@now), "target_url" => head }]
    @now += 60
    @poller.run
    assert_equal "success", handing.call(head)[:state]
    assert_equal "success", @port.approval_checks(card, deploy)[:state], "the Approve: the head's CI, any build"
  end

  # a queued check run has no started_at (and no check run has a created_at): its pending time counts from the later of
  # its check suite's created_at and the first poll that saw THIS run (by id) pending. A re-run reuses the old suite, so
  # one queued hours after the push is not stuck at once; a run queued forever is stuck max_pending_minutes after first
  # sight
  def test_a_queued_check_run_without_a_start_becomes_stuck_from_its_suite
    @http.pulls = [PR]
    @http.suites[77] = { "id" => 77, "created_at" => finish_at(@now - (5 * 3600)) } # the push, 5 h ago
    queued = ->(id) {
 [{ "id" => id, "status" => "queued", "started_at" => nil, "completed_at" => nil, "check_suite" => { "id" => 77 } }] }
    @http.runs = queued.call(501) # a re-run, queued now in the old suite
    seen = @now
    poll = lambda do |seconds|
      @now += seconds
      @port.pr_checks(@card)
      @poller.run
      @port.pr_checks(@card)
    end
    poll.call(0)
    assert_equal "pending", poll.call(0)[:state], "the suite is 5 h old, the run was first seen now"
    assert(@http.requests.any? { |u| u.end_with?("/repos/o/r/check-suites/77") })
    59.times { poll.call(60) } # 59 min after first sight, polled every minute
    assert_equal "pending", poll.call(0)[:state]
    got = poll.call(120)
    assert_equal ["stuck", seen + 3600], got.values_at(:state, :finished_at), "61 min after first sight"
    @http.runs = queued.call(502) # re-run again: a new run id, a new clock
    assert_equal "pending", poll.call(60)[:state]

    @http.suites[77] = { "id" => 77 }
    e = assert_raises(CK::Unavailable) { poll.call(60) }
    assert_match(/check suite 77 of jenkins\/ci has no created_at/, e.message)
  end

  # a finished required check GitHub gives no completion time: refused on its row, never assumed
  def test_a_finished_check_without_a_completion_time_is_refused
    @http.pulls = [PR]
    @http.runs = [{ "status" => "completed", "conclusion" => "success", "started_at" => finish_at(@now),
                    "completed_at" => nil, }]
    @port.pr_checks(@card)
    @poller.run
    e = assert_raises(CK::Unavailable) { @port.pr_checks(@card) }
    assert_match(/o\/r abc: finished check jenkins\/ci has no completion time/, e.message)
  end

  # the enrolled projects' local / public repos config ci.required does not list (shown on /github; never a boot refusal)
  def test_enrolled_repos_missing_from_ci_required_are_named
    ci = ci_settings
    assert_empty CK.unlisted(@conn, ci), "o-r is not enrolled: nothing to list"
    enrol!
    assert_empty CK.unlisted(@conn, ci), "o/r_local and o/r are listed"
    @conn[:projects].insert(slug: "x", path: "/projects/x", remote: "git@github.com:p/x_local.git", own: true,
                            commits_window: 0, mine_window: 0, dirty: 0, scanned_at: 0, local_mode: "upstream",
                            local_repo: "https://github.com/p/x_local.git", public_repo: "git@github.com:Up/X.git")
    assert_equal %w[Up/X p/x_local], CK.unlisted(@conn, ci)
  end

  # ── card #511: a card that waited in an approval gate longer than the poll window is approved on the first click ──

  # One card per approval gate of the local_v4 board, each with green CI as its step reads it: Local: Human review (the
  # open local PR), Local: Deploy check (the local PR merged + its merge commit's CI), Public: Human review and
  # Awaiting merge — the operator dragged that card there, unapproved: Approve approves it in place — (the
  # local PR merged + the open public PR). → {gate => card id}
  def gated_cards
    enrol!
    @kb.board_save("o-r", JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/" \
                                                                 "local_v4.board.json", __dir__))), by: "operator")
    merged = ->(n) { MERGED.merge("number" => n, "merge_commit_sha" => format("%040d", n)) }
    @http.pulls = [PR, merged[113], merged[114], merged[115], PUB, PUB.merge("number" => 6)]
    @http.statuses = [{ "state" => "success", "updated_at" => finish_at(@now) }]
    { "local_human_review" => [112, nil], "deploy_check" => [113, nil], "public_human_review" => [114, 5],
      "awaiting_merge" => [115, 6], }.to_h do |gate, (local, public)|
      id = @kb.create(slug: "o-r", title: gate, by: "lead", column: gate)
      @kb.assign_pr(id, url: "https://github.com/o/r_local/pull/#{local}", role: "local", by: "lead")
      @kb.assign_pr(id, url: "https://github.com/o/r/pull/#{public}", role: "public", by: "lead") if public
      [gate, id]
    end
  end

  def wait_in_the_gates(notifier, seconds)
    (seconds / 30).times do # notifier_watch_seconds = 30; the github service polls what was asked
      @now += 30
      notifier.watch
      @poller.run
    end
  end

  def test_each_approval_gate_s_first_approve_succeeds_after_waiting_longer_than_the_poll_window
    gates = gated_cards
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: StringIO.new)
    wait_in_the_gates(n, 2 * 600) # twice wanted_for
    assert_empty CK.stale_gates(@kb, @port), "the guard: every gated card's reads are inside the window"
    gates.each do |gate, id|
      @kb.approve(id, by: "operator") # "not read yet (asked now — try again in a minute)"
      assert @kb.card(id)[:approved_at], "#{gate}: approved on the first click"
    end
  end

  # the live guard: a card the operator can Approve whose reads fell out of the poll window is listed with each read
  # (never asked, or how long ago) and said by the notifier once per change, and once when fresh again
  def test_the_gate_guard_names_a_gated_card_whose_reads_left_the_window
    gates = gated_cards
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: StringIO.new)
    final = gates.fetch("awaiting_merge")
    never = CK.stale_gates(@kb, @port).find { |g| g[:card] == final }
    assert_equal({ card: final, project: "o-r", column: "awaiting_merge",
                   reads: [{ repo: "o/r_local", ref: "pr:115", age: nil }], }, never, "never asked")
    wait_in_the_gates(n, 120)
    assert_empty CK.stale_gates(@kb, @port)
    @now += 601 # no watch pass for longer than the window (the prefetch skipped them)
    stale = CK.stale_gates(@kb, @port).to_h { |g| [g[:card], g[:reads]] }
    assert_equal gates.values.sort, stale.keys.sort
    assert_equal [{ repo: "o/r_local", ref: "pr:115", age: 601 }, { repo: "o/r", ref: "pr:6", age: 601 }], stale[final]
    assert_equal [{ repo: "o/r_local", ref: "pr:113", age: 601 }, { repo: "o/r_local", ref: "merge:113", age: 601 }],
                 stale[gates.fetch("deploy_check")]
    assert_equal 0, @conn[:gh_pr_checks].where(Sequel.lit("requested_at > ?", @now - 601)).count, "the guard asks nothing"

    log = StringIO.new
    guard = CK::GateGuard.new(log: log, window: 600)
    guard.check(CK.stale_gates(@kb, @port))
    @now += 30 # the ages grow every pass — not a change, nothing said again
    guard.check(CK.stale_gates(@kb, @port))
    n.watch
    guard.check(CK.stale_gates(@kb, @port))
    lines = log.string.lines.map(&:chomp)
    assert_equal 8, lines.size, log.string
    assert_includes lines, "gate guard: card #{final} (awaiting_merge): o/r_local pr:115 last asked 601s ago; o/r pr:6 " \
                           "last asked 601s ago — not answered inside the 600s poll window: its Approve is refused " \
                           "until each is read"
    assert_includes lines, "gate guard: card #{final} reads fresh again"
  end

  # a row the github service failed to read refuses the Approve (Unavailable) — the guard names it
  # with the poll's error, said again only when the error changes
  def test_the_gate_guard_names_a_failed_poll
    gates = gated_cards
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: StringIO.new)
    wait_in_the_gates(n, 60)
    first = gates.fetch("local_human_review")
    @conn[:gh_pr_checks].where(repo: "o/r_local", ref: "pr:112").update(error: "403 rate limited")
    stale = CK.stale_gates(@kb, @port).to_h { |g| [g[:card], g[:reads]] }
    assert_equal({ first => [{ repo: "o/r_local", ref: "pr:112", age: 0, error: "403 rate limited" }] }, stale)
    log = StringIO.new
    guard = CK::GateGuard.new(log: log, window: 600)
    guard.check(CK.stale_gates(@kb, @port))
    @now += 30
    guard.check(CK.stale_gates(@kb, @port))
    @conn[:gh_pr_checks].where(repo: "o/r_local", ref: "pr:112").update(error: "502 bad gateway")
    guard.check(CK.stale_gates(@kb, @port))
    assert_equal ["gate guard: card #{first} (local_human_review): o/r_local pr:112 poll failed: 403 rate limited — " \
                  "not answered inside the 600s poll window: its Approve is refused until each is read",
                  "gate guard: card #{first} (local_human_review): o/r_local pr:112 poll failed: 502 bad gateway — " \
                  "not answered inside the 600s poll window: its Approve is refused until each is read",],
                 log.string.lines.map(&:chomp)
  end

  # public inside the window, a row the github service stopped answering refuses the Approve
  # (Unavailable) — the guard names it: requested and never polled, or an answer older than stale_after
  def test_the_gate_guard_names_a_stalled_github_service
    gates = gated_cards
    n = AgentsKanban::Notifier.new(@kb, client: @launcher, ci: @port, clock: -> { @now }, grace: 60, log: StringIO.new)
    wait_in_the_gates(n, 60)
    first = gates.fetch("local_human_review")
    @conn[:gh_pr_checks].where(repo: "o/r_local", ref: "pr:112").update(checked_at: @now - 181)
    assert_raises(CK::Unavailable) { @port.approval_checks(@kb.card(first), CK.steps(@kb.board_of("o-r")).first) }
    @conn[:gh_pr_checks].where(repo: "o/r_local", ref: "pr:112").update(checked_at: @now - 181, requested_at: @now)
    stale = CK.stale_gates(@kb, @port).to_h { |g| [g[:card], g[:reads]] }
    assert_equal({ first => [{ repo: "o/r_local", ref: "pr:112", age: 0,
                               why: "answer older than 180s (github service stopped?)", }] }, stale)
    @conn[:gh_pr_checks].where(repo: "o/r_local", ref: "pr:112").update(checked_at: nil, requested_at: @now - 181)
    assert_equal [{ repo: "o/r_local", ref: "pr:112", age: 181,
                    why: "requested, not polled within 180s (github service running?)", }],
                 CK.stale_gates(@kb, @port).to_h { |g| [g[:card], g[:reads]] }[first]
    log = StringIO.new
    CK::GateGuard.new(log: log, window: 600).check(CK.stale_gates(@kb, @port))
    assert_match(/card #{first} \(local_human_review\): o\/r_local pr:112 requested, not polled within 180s/, log.string)
  end
end
