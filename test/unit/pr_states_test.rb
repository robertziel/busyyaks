# frozen_string_literal: true

require "test_helper"
require "digest"
require "busyyaks/pr_states"

# PR flags — Poller (github side) + Reader (web side) over gh_pr_states, and the links they flag.
class PrStatesTest < Minitest::Test
  include DBReset
  PS = Busyyaks::PrStates

  class FakeHttp
    attr_accessor :pulls, :requests, :fail, :limited, :events, :events_limited
    attr_reader :etags_sent

    def initialize = (@requests = []; @pulls = []; @events = {})
    def get(url, headers)
      raise "no token" unless headers["Authorization"]
      @requests << url
      (@etags_sent ||= []) << headers["If-None-Match"] if url.include?("/pulls/")
      return [401, {}, "{\"message\":\"Bad credentials\"}"] if @fail
      if @limited # the token's limit used up: x-ratelimit-reset = @limited
        return [403, { "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => @limited.to_s },
                "{\"message\":\"API rate limit exceeded for user\"}",]
      end

      # a PR's issue events: @events[n] = its pages (each an array, oldest first); a closed PR with none set was
      # closed by octo
      m = url.match(%r{/issues/(\d+)/events\?per_page=100(?:&page=(\d+))?\z})
      if m && @events_limited # the token's limit used up on the events read
        return [403, { "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => @events_limited.to_s },
                "{\"message\":\"API rate limit exceeded for user\"}",]
      end
      return [500, {}, "{\"message\":\"Server Error\"}"] if m && @events == :fail
      if m
        n = m[1].to_i
        pages = @events.fetch(n) { [[{ "event" => "closed", "actor" => { "login" => "octo" } }]] }
        i = (m[2] || 1).to_i
        link = i < pages.size ? { "link" => "<https://api.github.com/repos/x/issues/#{n}/events?per_page=100&page=#{i + 1}>; rel=\"next\"" } : {}
        return [200, link, JSON.generate(pages[i - 1])]
      end

      body = case url
             when %r{/pulls\?state=all&head=([^&]+)}
               head = URI.decode_www_form_component(Regexp.last_match(1))
               @pulls.select { |p| p["head_label"] == head }
             when %r{/pulls/(\d+)\z} then @pulls.find { |p| p["number"] == Regexp.last_match(1).to_i }
             end
      return [404, {}, "{\"message\":\"Not Found\"}"] if body.nil?

      json = JSON.generate(body)
      etag = "\"#{Digest::SHA1.hexdigest(json)}\""
      return [304, {}, ""] if headers["If-None-Match"] == etag # GitHub: unchanged since that ETag, not rate-counted

      [200, { "etag" => etag }, json]
    end
  end

  # base: a local repo's PR is on `local`, any other on `main` (ENROLLED's bases); open and mergeable unless said
  def pr(n, repo, state: "open", draft: false, merged: nil, head: nil, closed: "2026-11-16T23:06:57Z", **more)
    { "number" => n, "state" => state, "draft" => draft, "merged_at" => merged,
      "closed_at" => state == "closed" ? merged || closed : nil,
      "html_url" => "https://github.com/#{repo}/pull/#{n}", "head_label" => head,
      "base" => { "ref" => repo.end_with?("_local") ? "local" : "main" }, "mergeable" => true,
      "mergeable_state" => "clean", "auto_merge" => nil, }.merge(more.transform_keys(&:to_s))
  end

  def ev(kind, login = "robertziel") = { "event" => kind, "actor" => { "login" => login } }

  # busyyaks PR #43 — its base branch was deleted by a ship (GitHub closes, never retargets)
  def test_closed_by_a_deleted_base_says_why
    @http.pulls = [pr(43, "o/m", state: "closed")]
    @http.events = { 43 => [[ev("base_ref_force_pushed"), ev("base_ref_deleted")], [ev("closed")]] } # two pages
    @reader.lookup("o/m", "pr:43")
    @poller.run
    st = @reader.lookup("o/m", "pr:43")
    assert_equal ["closed", "base deleted", Time.iso8601("2026-11-16T23:06:57Z").to_i],
                 st.values_at(:state, :reason, :closed_at)
    @now += 60
    @http.requests.clear
    @poller.run
    assert_equal ["/repos/o/m/pulls/43"], @http.requests.map { |u| u.delete_prefix("https://api.github.com") },
                 "the reason is read once per close"
    link = links_for({ slug: "g/m", local_mode: nil }, [],
                     metadata: prs_meta("pr", "https://github.com/o/m/pull/43")).first
    assert_equal ["#43 m [closed: base deleted]"], shown([link])
    assert_equal "base deleted", detail(link)["Why closed"]
    assert_equal "closed without merging", detail(link)["State"]
  end

  # the real GitHub answer for busyyaks PR #43 (gh api repos/robertziel/busyyaks/issues/43/events, 2026-11-16):
  # base_ref_deleted and closed in the same second
  def test_the_recorded_pr_43_events_say_base_deleted
    @http.pulls = [pr(43, "o/m", state: "closed", closed: "2026-11-15T23:06:57Z")]
    @http.events = { 43 => [JSON.parse(File.read(File.expand_path("../fixtures/github/issue_43_events.json", __dir__)))] }
    @reader.lookup("o/m", "pr:43")
    @poller.run
    assert_equal "base deleted", @reader.lookup("o/m", "pr:43")[:reason]
  end

  # the deletion written in the close's own second but AFTER it is still why; one a minute later is a cleanup
  def test_a_deleted_branch_in_the_closes_second_after_it_is_why_a_later_one_is_not
    at = "2026-11-15T23:06:57Z"
    { [ev("closed").merge("created_at" => at), ev("head_ref_deleted").merge("created_at" => at)] => "head deleted",
      [ev("closed").merge("created_at" => at), ev("base_ref_deleted").merge("created_at" => at)] => "base deleted",
      [ev("closed", "ann").merge("created_at" => at),
       ev("head_ref_deleted").merge("created_at" => "2026-11-15T23:07:58Z"),] => "by ann", }.each_with_index do |(evs, why), i|
      n = 60 + i
      @http.pulls = [pr(n, "o/m", state: "closed")]
      @http.events = { n => [evs] }
      @reader.lookup("o/m", "pr:#{n}")
      @poller.run
      assert_equal why, @reader.lookup("o/m", "pr:#{n}")[:reason], evs.map { |e| e["event"] }.inspect
    end
  end

  # a closed PR GitHub gave no closed_at: stored closed, the reason says so (the PR watch says it as the PR's error,
  # never told under a made-up time)
  def test_a_closed_pr_with_no_closed_at_is_stored_with_an_unknown_reason
    @http.pulls = [pr(6, "o/m", state: "closed").merge("closed_at" => nil)]
    @reader.lookup("o/m", "pr:6")
    @poller.run
    st = @reader.lookup("o/m", "pr:6")
    assert_equal ["closed", nil, "unknown: GitHub gave o/m#6 no closed_at"], st.values_at(:state, :closed_at, :reason)
  end

  def test_closed_by_a_deleted_head_says_why
    @http.pulls = [pr(7, "o/m", state: "closed")]
    # closed by hand and reopened earlier; the last close came from the head branch's deletion
    @http.events = { 7 => [[ev("closed", "ann"), ev("reopened"), ev("head_ref_deleted"), ev("closed")]] }
    @reader.lookup("o/m", "pr:7")
    @poller.run
    assert_equal "head deleted", @reader.lookup("o/m", "pr:7")[:reason]
  end

  def test_closed_by_hand_names_who_and_a_head_deleted_after_the_close_is_not_the_reason
    @http.pulls = [pr(8, "o/m", state: "closed")]
    @http.events = { 8 => [[ev("closed", "ann").merge("created_at" => "2026-11-15T10:00:00Z"),
                            ev("head_ref_deleted").merge("created_at" => "2026-11-15T10:05:00Z"),]] }
    @reader.lookup("o/m", "pr:8")
    @poller.run
    assert_equal "by ann", @reader.lookup("o/m", "pr:8")[:reason]
  end

  def test_a_reopened_pr_closed_again_reads_its_new_reason
    @http.pulls = [pr(9, "o/m", state: "closed")]
    @reader.lookup("o/m", "pr:9")
    @poller.run
    assert_equal "by octo", @reader.lookup("o/m", "pr:9")[:reason]
    @http.pulls = [pr(9, "o/m", state: "closed", closed: "2026-11-17T08:00:00Z")]
    @http.events = { 9 => [[ev("closed", "octo"), ev("reopened"), ev("base_ref_deleted"), ev("closed")]] }
    @now += 60
    @poller.run
    assert_equal ["base deleted", Time.iso8601("2026-11-17T08:00:00Z").to_i],
                 @reader.lookup("o/m", "pr:9").values_at(:reason, :closed_at)
    @http.pulls = [pr(9, "o/m")]
    @now += 60
    @poller.run
    refute @reader.lookup("o/m", "pr:9").key?(:reason), "an open PR carries no close"
  end

  # GitHub has no reason for the close (no closed event): stored as "unknown: …" for that close, never re-read
  def test_a_closed_pr_github_gives_no_reason_for_is_closed_with_an_unknown_reason_read_once
    @http.pulls = [pr(5, "o/m", state: "closed")]
    @http.events = { 5 => [[ev("labeled")]] }
    @reader.lookup("o/m", "pr:5")
    @poller.run
    st = @reader.lookup("o/m", "pr:5")
    assert_equal "closed", st[:state]
    assert_equal "unknown: o/m#5 is closed but its issue events have no closed event", st[:reason]
    link = links_for({ slug: "g/m", local_mode: nil }, [],
                     metadata: prs_meta("pr", "https://github.com/o/m/pull/5")).first
    assert_equal ["#5 m [closed: why unknown]"], shown([link])
    @http.requests.clear
    @now += 60
    @poller.run
    refute(@http.requests.any? { |u| u.include?("/events") }, "the same close's reason is not read again")
    assert_equal st[:reason], @reader.lookup("o/m", "pr:5")[:reason]
  end

  # a failed events read is the row's error, never the close's reason: read again next poll, the reason stored then
  def test_a_failed_reason_read_is_the_rows_error_and_is_read_again
    @http.pulls = [pr(5, "o/m", state: "closed")]
    @http.events = :fail
    @reader.lookup("o/m", "pr:5")
    @poller.run
    row = @db[:gh_pr_states].first
    assert_nil row[:reason], "never an unknown reason from a failed read"
    assert_match(/GitHub 500/, row[:error])
    assert_match(/\AGitHub read failed: GitHub 500/, @reader.lookup("o/m", "pr:5")[:error])
    @http.events = { 5 => [[ev("base_ref_deleted"), ev("closed")]] }
    @now += 60
    @poller.run
    assert_equal ["closed", "base deleted"], @reader.lookup("o/m", "pr:5").values_at(:state, :reason)
  end

  def test_a_closed_event_with_no_actor_is_closed_by_an_unknown_account
    @http.pulls = [pr(5, "o/m", state: "closed")]
    @http.events = { 5 => [[ev("closed").merge("actor" => nil)]] }
    @reader.lookup("o/m", "pr:5")
    @poller.run
    assert_equal "by an unknown account", @reader.lookup("o/m", "pr:5")[:reason]
  end

  # a row polled as closed before closed_at / reason existed: read as closed with no reason until the poller re-reads
  # it, then it has both
  def test_a_closed_row_polled_before_the_reason_existed_gets_it_on_the_next_poll
    @db[:gh_pr_states].insert(repo: "o/m", ref: "pr:5", number: 5, state: "closed", checked_at: @now,
                              requested_at: @now)
    assert_equal [nil, nil], @reader.lookup("o/m", "pr:5").values_at(:closed_at, :reason)
    @http.pulls = [pr(5, "o/m", state: "closed")]
    @http.events = { 5 => [[ev("closed", "ann")]] }
    @now += 60
    @poller.run
    st = @reader.lookup("o/m", "pr:5")
    assert_equal "by ann", st[:reason]
    assert_kind_of Integer, st[:closed_at]
  end

  def setup
    super
    @db = Hanami.app["db.gateway"].connection
    @now = 1_000_000
    @http = FakeHttp.new
    @client = client = Busyyaks::GithubNetwork::Client.new(token: "t", http: @http)
    @gate = Busyyaks::GithubPollers.new(db: @db, clock: -> { @now })
    @poller = PS::Poller.new(db: @db, client: client, gate: @gate, wanted_for: 600, clock: -> { @now })
    @reader = PS::Reader.new(db: @db, stale_after: 180, wanted_for: 600, clock: -> { @now })
    @flags = PS::Flags.new(@reader, enrolled: -> { @db[:projects].exclude(local_mode: nil).all }, clock: -> { @now })
  end

  def test_states_open_draft_merged_closed_and_a_merged_pr_is_polled_once
    @http.pulls = [pr(1, "o/m"), pr(2, "o/m", draft: true), pr(3, "o/m", state: "closed", merged: "2026-11-08T10:00:00Z"),
                   pr(4, "o/m", state: "closed"),]
    (1..4).each { |n| assert_equal({ state: "checking" }, @reader.lookup("o/m", "pr:#{n}")) }
    assert_equal 4, @poller.run
    assert_equal %w[open draft merged closed], (1..4).map { |n| @reader.lookup("o/m", "pr:#{n}")[:state] }
    assert_equal "https://github.com/o/m/pull/3", @reader.lookup("o/m", "pr:3")[:url]
    @now += 60
    @http.requests.clear
    assert_equal 3, @poller.run, "merged is final"
    refute @http.requests.any? { |u| u.end_with?("/pulls/3") }
  end

  # a rate limit is the token's, never a PR's state — it pauses the pollers until the reset (the rest of the batch says
  # so, nothing more is sent); the PRs are read after it
  def test_a_rate_limit_pauses_the_gate_until_the_reset
    @http.pulls = [pr(5, "o/m"), pr(6, "o/m")]
    @http.limited = @now + 900
    @reader.lookup("o/m", "pr:5")
    @reader.lookup("o/m", "pr:6")
    @poller.run
    assert_match(/\Apolling paused until .*rate limit/, @gate.paused)
    @db[:gh_pr_states].order(:ref).select_map(%i[ref state error]).each do |ref, state, error|
      assert_nil state, "#{ref}: no state stored"
      assert_match(/\Apolling paused until /, error, ref)
    end
    assert_equal 1, @http.requests.size, "pr:5 refused: pr:6 not sent"
    @http.requests.clear
    @poller.run
    assert_empty @http.requests, "paused: nothing sent"
    @now += 901
    @http.limited = nil
    %w[pr:5 pr:6].each { |r| @reader.lookup("o/m", r) } # still wanted after the pause
    @poller.run
    assert_equal %w[open open], %w[pr:5 pr:6].map { |r| @reader.lookup("o/m", r)[:state] }
  end

  # a rate limit on a close's issue-events read is the token's, never the close's reason — it pauses
  # the pollers until the reset (the rest of the batch says so, nothing more is sent); the close is read after it
  def test_a_rate_limit_on_the_issue_events_read_pauses_the_gate
    @http.pulls = [pr(5, "o/m", state: "closed"), pr(6, "o/m")]
    @http.events_limited = @now + 900
    @reader.lookup("o/m", "pr:5")
    @reader.lookup("o/m", "pr:6")
    @poller.run
    assert_match(/\Apolling paused until .*rate limit/, @gate.paused)
    errors = @db[:gh_pr_states].order(:ref).select_map(%i[ref state reason error])
    errors.each do |ref, state, reason, error|
      assert_nil state, "#{ref}: no state stored"
      assert_nil reason, "#{ref}: never an unknown reason"
      assert_match(/\Apolling paused until /, error, ref)
    end
    assert_equal 2, @http.requests.size, "the PR, then its events: pr:6 not sent"
    @http.requests.clear
    @poller.run
    assert_empty @http.requests, "paused: nothing sent"
    @now += 901
    @http.events_limited = nil
    %w[pr:5 pr:6].each { |r| @reader.lookup("o/m", r) } # still wanted after the pause
    @poller.run
    assert_equal ["closed", "by octo"], @reader.lookup("o/m", "pr:5").values_at(:state, :reason)
  end

  # a closed PR's state survives a 304 — closed_at comes from the cached fields, so the close (and its
  # reason, read once) is kept and the events are not read again
  # an upgrade that adds a KEEP field: a cache entry written with the old field set — under main's plain `pr:<url>` key or
  # a digest of another set — is never read and its ETag never sent, so the next read is a full 200 that stores
  # closed_at; a closed PR polled before the upgrade is told once, with its real time and reason
  def test_a_cache_entry_written_with_another_field_set_is_not_used
    url = "/repos/o/m/pulls/5"
    old = { "number" => 5, "html_url" => "https://github.com/o/m/pull/5", "state" => "closed", "draft" => false,
            "merged_at" => nil, }
    ["pr:#{url}", Busyyaks::GithubNetwork.cache_key("pr:", PS::Poller::KEEP - ["closed_at"], url)].each do |key|
      @db[:gh_pages].insert(url: key, etag: "\"old\"", items: JSON.generate(old), at: @now)
    end
    @db[:gh_pr_states].insert(repo: "o/m", ref: "pr:5", number: 5, state: "closed", checked_at: @now - 60,
                              requested_at: @now)
    @http.pulls = [pr(5, "o/m", state: "closed")]
    @http.events = { 5 => [[ev("closed", "ann")]] }
    @poller.run
    assert_equal [nil], @http.etags_sent, "no If-None-Match: a full read"
    assert_equal 0, @client.not_modified
    st = @reader.lookup("o/m", "pr:5")
    assert_equal [Time.iso8601("2026-11-16T23:06:57Z").to_i, "by ann"], st.values_at(:closed_at, :reason)
    assert_includes JSON.parse(@db[:gh_pages].where(url: PS::Poller.cache_key(url)).get(:items)).keys, "closed_at"
    refute_equal PS::Poller.cache_key(url), Busyyaks::GithubNetwork.cache_key("pr:", PS::Poller::KEEP - ["draft"], url)
  end

  def test_an_unchanged_closed_pr_keeps_its_closed_at_on_a_304
    @http.pulls = [pr(7, "o/m", state: "closed")]
    @reader.lookup("o/m", "pr:7")
    @poller.run
    first = @db[:gh_pr_states].where(ref: "pr:7").first
    @now += 60
    @http.requests.clear
    @reader.lookup("o/m", "pr:7")
    @poller.run
    assert_equal 1, @client.not_modified, "the second read is a 304"
    assert_equal ["/repos/o/m/pulls/7"], @http.requests.map { |u| u.delete_prefix("https://api.github.com") },
                 "one conditional read, no events"
    row = @db[:gh_pr_states].where(ref: "pr:7").first
    assert_equal Time.iso8601("2026-11-16T23:06:57Z").to_i, row[:closed_at], "closed_at from the 304's cached fields"
    assert_equal [first[:closed_at], "by octo", "closed", nil], row.values_at(:closed_at, :reason, :state, :error)
  end

  # a wanted PR is read every minute; while it stands still each read is a 304 (no rate limit), and only the fields the
  # state needs are cached, pruned once nobody asked for the PR for wanted_for
  def test_an_unchanged_pr_state_costs_no_rate_limit
    @http.pulls = [pr(1, "o/m")]
    @reader.lookup("o/m", "pr:1")
    @poller.run
    assert_equal 1, @client.calls
    30.times do
      @now += 60
      @reader.lookup("o/m", "pr:1")
      @poller.run
    end
    assert_equal 1, @client.calls, "30 polls later: every read a 304"
    assert_equal 30, @client.not_modified
    assert_equal "open", @reader.lookup("o/m", "pr:1")[:state]
    assert_equal @now, @reader.lookup("o/m", "pr:1")[:checked_at], "a 304 is a fresh read"
    @http.pulls = [pr(1, "o/m", draft: true, base: { "ref" => "main", "repo" => { "full_name" => "o/m" } })]
    @now += 60
    @poller.run
    assert_equal 2, @client.calls, "the change is read"
    assert_equal "draft", @reader.lookup("o/m", "pr:1")[:state]
    page = @db[:gh_pages].where(url: PS::Poller.cache_key("/repos/o/m/pulls/1")).first
    items = JSON.parse(page[:items])
    assert_equal %w[auto_merge base closed_at draft html_url mergeable mergeable_state merged_at number state],
                 items.keys.sort
    assert_equal ["ref"], items["base"].keys, "the base branch's name only, never its repo object"
    @now += 601
    @poller.run
    assert_nil @db[:gh_pages].where(url: PS::Poller.cache_key("/repos/o/m/pulls/1")).first, "nobody asked for 10 min: pruned"
  end

  # only PRs assigned to cards are read — a head: ref (the old branch lookup) is an error on its row
  def test_a_head_ref_is_not_read
    @reader.lookup("o/p", "head:o:fix/settings-toggle")
    @poller.run
    error = @reader.lookup("o/p", "head:o:fix/settings-toggle")[:error]
    assert_match(/o\/p head:o:fix\/settings-toggle: not a pr:<n> ref/, error)
    assert_empty @http.requests
  end

  def test_failed_and_stale_reads_are_said_never_shown_as_a_state
    @reader.lookup("o/m", "pr:1")
    @http.fail = true
    @poller.run
    assert_match(/GitHub read failed: .*401/, @reader.lookup("o/m", "pr:1")[:error])
    @http.fail = false
    @http.pulls = [pr(1, "o/m")]
    @poller.run
    assert_equal "open", @reader.lookup("o/m", "pr:1")[:state]
    @now += 181
    assert_match(/last GitHub read 3 min ago/, @reader.lookup("o/m", "pr:1")[:error])
    @reader.lookup("o/m", "pr:9")
    @now += 181
    assert_match(/not read by the github service 181s/, @reader.lookup("o/m", "pr:9")[:error])
  end

  # a card nobody opened for longer than wanted_for was not polled — its old answer is "checking", not an outage
  def test_reopened_after_the_wanted_window_reads_checking_then_the_fresh_state
    @http.pulls = [pr(1, "o/m")]
    @reader.lookup("o/m", "pr:1")
    10.times { @poller.run; @now += 60 } # the service polls every interval while the row is wanted (600 s)
    @poller.run
    @now += 60
    assert_equal 0, @poller.run, "nobody asked for 660 s: not polled"
    @now += 300 # the last answer (at 600 s) is now 6 min old — not shown, because nobody was looking
    assert_equal({ state: "checking" }, @reader.lookup("o/m", "pr:1"))
    @http.pulls = [pr(1, "o/m", state: "closed")]
    assert_equal 1, @poller.run
    assert_equal "closed", @reader.lookup("o/m", "pr:1")[:state]
  end

  # a 404 is an error (token cannot see the repo), and any exception stays on its row
  def test_a_missing_pr_and_a_broken_row_are_errors_not_states
    @reader.lookup("o/m", "pr:404")
    @reader.lookup("o/m", "pr:abc")
    @http.pulls = [pr(1, "o/m")]
    @reader.lookup("o/m", "pr:1")
    assert_equal 3, @poller.run
    assert_match(/o\/m#404: 404 — no such PR, or the token cannot see the repo/, @reader.lookup("o/m", "pr:404")[:error])
    assert_match(/ArgumentError/, @reader.lookup("o/m", "pr:abc")[:error])
    assert_equal "open", @reader.lookup("o/m", "pr:1")[:state], "the batch went on"
  end

  def test_rows_nobody_asked_for_recently_are_not_polled
    @reader.lookup("o/m", "pr:1")
    @now += 601
    assert_equal 0, @poller.run
  end

  ENROLLED = { slug: "g/widgets", path: "/repos/widgets", remote: "https://github.com/o/widgets_local.git",
             pr_remote: "https://github.com/o/widgets_local.git", local_mode: "own",
             local_repo: "https://github.com/o/widgets_local.git", public_repo: "https://github.com/o/widgets.git",
             public_head: "https://github.com/o/widgets.git", local_base: "local", public_base: "main",
             local_error: nil, }.freeze

  # "label [tag tag]" — what the rail shows
  def shown(links) = links.map { |l| l[:tags] ? "#{l[:label]} [#{l[:tags].map { |t| t[:text] }.join(' ')}]" : l[:label] }
  def detail(link) = link[:detail].to_h { |r| [r[:label], r[:value]] }

  # metadata prs as kanban_pr_assign writes it (a list): prs_meta("local", url, "public", url, …)
  def self.prs_meta(*pairs)
    { "prs" => pairs.each_slice(2).map { |role, url| { "url" => url, "role" => role, "by" => "agent-1", "at" => 1 } } }
  end
  def prs_meta(...) = self.class.prs_meta(...)

  PUB12 = prs_meta("public", "https://github.com/o/widgets/pull/12").freeze

  def links_for(project, links, id: 158, metadata: nil)
    @flags.apply(links, { id: id, metadata: metadata }, project)
  end

  # the PRs assigned to the card (metadata prs) are its PR rows, flagged with role + state, grouped by role
  def test_enrolled_project_flags_local_and_public_prs_with_their_state
    links = [{ kind: "repo", label: "g/widgets", url: "https://github.com/o/widgets_local" }]
    both = prs_meta("public", "https://github.com/o/widgets/pull/12", "local", "https://github.com/o/widgets_local/pull/5")
    first = links_for(ENROLLED, links, metadata: both)
    assert_equal ["g/widgets", "#5 widgets_local [local checking]", "#12 widgets [public checking]"], shown(first),
                 "role order: local first"
    assert_equal "waiting for the github service", detail(first[1])["Read"]
    assert_equal [%w[o/widgets pr:12], %w[o/widgets_local pr:5]],
                 @db[:gh_pr_states].order(:repo).select_map(%i[repo ref]), "by number, never by a branch name"
    @http.pulls = [pr(5, "o/widgets_local", state: "closed", merged: "2026-11-08T11:00:00Z"),
                   pr(12, "o/widgets", head: "o:fix/scanner-skips-worktrees"),]
    @poller.run
    out = links_for(ENROLLED, links, metadata: both)
    assert_equal ["#5 widgets_local [local merged]", "#12 widgets [public open checks: not read yet]"], shown(out.drop(1))
    assert_equal [%w[local info], %w[merged done]], out[1][:tags].map { |t| t.values_at(:text, :tone) }
    assert_equal({ "Repo" => "o/widgets_local", "Role" => "private local repo", "State" => "merged", "Base" => "local",
                   "Assigned" => "agent-1 · #{Time.at(1).strftime('%Y-%m-%d %H:%M:%S %Z')}",
                   "Read" => "#{Time.at(@now).strftime('%Y-%m-%d %H:%M:%S %Z')} (GitHub)", },
                 detail(out[1]))
    @now += 30
    assert_equal out, links_for(ENROLLED, links, metadata: both),
                 "no clock in the JSON: the card rev changes only with a new GitHub read"
    assert_equal "public repo", detail(out[2])["Role"]
    assert_equal "https://github.com/o/widgets/pull/12", out.last[:url]
    assert_equal [[nil, "repo"], %w[local pr], %w[public pr]], out.map { |l| [l[:group], l[:kind]] }
  end

  # every PR is a row — several per role, several repos (busyyaks + the engine it vendors)
  def test_every_assigned_pr_is_a_row
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/5", "public", "https://github.com/o/widgets/pull/12",
                    "local", "https://github.com/o/engine_local/pull/91", "local", "https://github.com/o/widgets_local/pull/6")
    out = links_for(ENROLLED, [], metadata: meta)
    assert_equal ["#5 widgets_local [local checking]", "#91 engine_local [local checking]",
                  "#6 widgets_local [local checking]", "#12 widgets [public checking]",], shown(out)
    assert_equal 4, @db[:gh_pr_states].count
    assert(out.all? { |l| l[:unassign] }, "every assigned PR row offers the operator's unassign")
    why = "v14: o/cf_local is in no role this project reads (project not enrolled)"
    gone = meta.merge("prs_removed" => [{ "url" => "https://github.com/o/cf_local/pull/4", "role" => "local",
                                          "removed_by" => "migration", "removed_at" => 2, "reason" => why, }])
    last = links_for(ENROLLED, [], metadata: gone).last
    # the chip = the day in the server's zone; its year left out while it is the clock's (any zone: 1970 or 1969)
    day = Time.at(2).strftime(Time.at(2).year == Time.at(@now).year ? "%m-%d" : "%Y-%m-%d")
    assert_equal ["#4 cf_local", "removed", [[day, "muted"]], nil, true],
                 [last[:label], last[:group], last[:tags].map { |t| t.values_at(:text, :tone) }, last[:unassign],
                  last[:struck],]
    assert_equal ["migration · #{Time.at(2).strftime('%Y-%m-%d %H:%M:%S %Z')}", why],
                 detail(last).values_at("Removed", "Why")
    # another year than the clock's: the year is said (server zone, as the hover's time)
    later = @now + (400 * 86_400)
    other_year = gone.merge("prs_removed" => [gone["prs_removed"].first.merge("removed_at" => later)])
    assert_equal [Time.at(later).strftime("%Y-%m-%d")],
                 links_for(ENROLLED, [], metadata: other_year).last[:tags].map { |t| t[:text] }
    bare = meta.merge("prs_removed" => [{ "url" => "https://github.com/o/cf_local/pull/4" }])
    assert_equal [%w[removed muted]], links_for(ENROLLED, [], metadata: bare).last[:tags].map { |t| t.values_at(:text, :tone) }
    refute(out.any? { |l| l.key?(:struck) }, "an assigned PR is not struck")
    assert_equal 4, @db[:gh_pr_states].count, "a removed PR is never polled"
    refute links_for(ENROLLED.merge(local_error: "x"), [], metadata: meta).last.key?(:unassign), "the config row does not"
    old = { "prs" => [{ "url" => "https://github.com/o/widgets_local/pull/5", "role" => "local" }] } # migrated: no by/at
    assert_equal "not recorded", detail(links_for(ENROLLED, [], metadata: old)[0])["Assigned"]
  end

  # no PR assigned → no row and nothing asked (a placeholder is not a pull request, a branch name is not guessed); the
  # same PR pasted as a URL stays a plain link beside its row
  def test_no_public_pr_recorded_shows_no_row_and_a_pasted_url_stays_a_link
    assert_equal [], links_for(ENROLLED, [])
    assert_equal [], links_for(ENROLLED, [], metadata: { "prs" => [] })
    assert_equal [], @db[:gh_pr_states].select_map(:ref)
    @http.pulls = [pr(12, "o/widgets")]
    listed = [{ kind: "url", label: "github.com/o/widgets/pull/12", url: "https://github.com/o/widgets/pull/12" }]
    links_for(ENROLLED, listed, metadata: PUB12)
    @poller.run
    out = links_for(ENROLLED, listed, metadata: PUB12)
    assert_equal ["github.com/o/widgets/pull/12", "#12 widgets [public open checks: not read yet]"], shown(out)
    assert_equal %w[url pr], out.map { |l| l[:kind] }
    assert_equal ["github.com/o/widgets/pull/12"], shown(links_for(ENROLLED, listed)), "a pasted URL is not a PR row"
  end

  # review round 1: a raw `cards` row carries metadata as JSON text (the engine's watch pass, waiting counts)
  def test_assigned_reads_a_raw_rows_json_metadata
    want = [{ url: "https://github.com/o/widgets/pull/12", repo: "o/widgets", number: 12, role: "public", by: "agent-1",
              at: 1, }]
    assert_equal want, PS.assigned({ id: 158, metadata: JSON.generate(PUB12) }, "public")
    assert_equal want, PS.assigned({ id: 158, metadata: PUB12 })
    assert_empty PS.assigned({ id: 158, metadata: nil }, "public")
    assert_empty PS.assigned({ id: 158, metadata: PUB12 }, "local"), "by role"
    e = assert_raises(PS::Invalid) { PS.assigned({ id: 158, metadata: "{nope" }, "public") }
    assert_match(/\Acard #158 metadata is not JSON: /, e.message)
    e = assert_raises(PS::Invalid) { PS.assigned({ id: 158, metadata: { "prs" => { "public" => "x" } } }) }
    assert_match(/\Acard #158 metadata prs is not a list of PRs: /, e.message, "the pre-list shape is never read as none")
    e = assert_raises(PS::Invalid) { PS.assigned({ id: 158, metadata: { "prs" => [{ "url" => "#12", "role" => "pr" }] } }) }
    assert_match(/metadata prs has an entry that is no PR URL: /, e.message)
  end

  # a list that is not one of PRs is said on the card, never followed
  def test_a_broken_list_is_said
    out = links_for(ENROLLED, [], metadata: { "prs" => [{ "url" => "nope", "role" => "public" }] })
    assert_equal ["PRs [unknown]"], shown(out)
    assert_match(/card #158 metadata prs has an entry that is no PR URL: /, detail(out[0])["Why"])
    assert_equal "/projects/g/widgets", out[0][:url]
    assert_equal [], @db[:gh_pr_states].select_map(:ref)
  end

  # upstream mode with no readable public repo — the local PRs still rows, the enrolment's reason said beside them
  def test_an_unreadable_public_repo_keeps_the_rows_and_says_why
    up = ENROLLED.merge(local_mode: "upstream", public_repo: nil, public_head: nil,
                        local_error: 'guard.upstream names remote "upstream", which has no URL')
    out = links_for(up, [], id: 9, metadata: prs_meta("local", "https://github.com/o/widgets_local/pull/3"))
    assert_equal ["#3 widgets_local [local checking]", "config [local unknown]"], shown(out)
    assert_equal 'guard.upstream names remote "upstream", which has no URL', detail(out.last)["Why"]
    assert_equal "warn", out.last[:tags].last[:tone]
    assert_equal "/projects/g/widgets", out.last[:url]
  end

  # another PR of the public repo pasted in the text (background, a follow-up) is a plain link, never a PR row
  def test_another_public_pr_in_the_text_is_a_link_not_a_row
    @http.pulls = [pr(4, "o/widgets"), pr(12, "o/widgets")]
    named = [{ kind: "url", label: "github.com/o/widgets/pull/4", url: "https://github.com/o/widgets/pull/4" }]
    links_for(ENROLLED, named, metadata: PUB12)
    @poller.run
    assert_equal ["github.com/o/widgets/pull/4", "#12 widgets [public open checks: not read yet]"],
                 shown(links_for(ENROLLED, named, metadata: PUB12))
    assert_equal [%w[o/widgets pr:12]], @db[:gh_pr_states].select_map(%i[repo ref]), "the pasted PR is not read"
  end

  # a PR number in the text names no repo (it was resolved against the card's own repo, so a PR of another repo showed
  # as an unrelated [local] row); neither it nor the handoff pr_url is ever a row: the rows are the assigned PRs
  def test_text_pr_refs_and_the_handoff_pr_are_never_rows
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/139")
    text = [{ kind: "pr", label: "#139", url: "https://github.com/o/widgets_local/pull/139" }, # the handoff pr_url
            { kind: "pr", label: "#63", url: "https://github.com/o/widgets_local/pull/63" },   # "engine PR #63"
            { kind: "pr", label: "#13", url: "https://github.com/o/widgets_local/pull/13" },]  # "public PR #13"
    assert_equal ["#139 widgets_local [local checking]"], shown(links_for(ENROLLED, text, metadata: meta))
    assert_equal [%w[o/widgets_local pr:139]], @db[:gh_pr_states].select_map(%i[repo ref]), "#63 / #13 are not read"
    assert_equal [], links_for(ENROLLED, text), "nothing assigned → no PR row at all"
    plain = { slug: "g/r", remote: "https://github.com/o/r.git", local_mode: nil, local_error: nil }
    assert_equal [], links_for(plain, [{ kind: "pr", label: "#7", url: "https://github.com/o/r/pull/7" }])
    assert_equal [], @flags.apply(text, { id: 1 }, nil), "no project: no PR rows either"
  end

  def test_upstream_mode_reads_the_public_pr_on_the_upstream_repo
    up = ENROLLED.merge(local_mode: "upstream", public_repo: "https://github.com/ruby/ruby.git",
                        public_head: "https://github.com/me/ruby.git")
    links_for(up, [], id: 9, metadata: prs_meta("public", "https://github.com/ruby/ruby/pull/77"))
    assert_equal [%w[ruby/ruby pr:77]], @db[:gh_pr_states].select_map(%i[repo ref])
  end

  # the local PR assigned to the card is listed with no text naming it; a branch is never looked up
  def test_the_assigned_local_pr_is_listed_without_text
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/45")
    assert_equal ["#45 widgets_local [local checking]"], shown(links_for(ENROLLED, [], metadata: meta))
    @http.pulls = [pr(45, "o/widgets_local")]
    @poller.run
    branch = { kind: "branch", label: "card/158-a", url: "https://github.com/o/widgets_local/tree/card/158-a" }
    out = links_for(ENROLLED, [branch], metadata: meta)
    assert_equal ["card/158-a", "#45 widgets_local [local open checks: not read yet]"], shown(out)
    assert_equal [%w[o/widgets_local pr:45]], @db[:gh_pr_states].select_map(%i[repo ref]), "the branch is not looked up"
  end

  # a plain project's card: its `pr` PR, no role tag, no group
  def test_a_plain_projects_assigned_pr_has_no_role
    plain = { slug: "g/r", path: "/repos/r", remote: "https://github.com/o/r.git", pr_remote: "https://github.com/o/r.git",
              local_mode: nil, local_error: nil, }
    meta = prs_meta("pr", "https://github.com/o/r/pull/7")
    links_for(plain, [], metadata: meta)
    @http.pulls = [pr(7, "o/r")]
    @poller.run
    assert_equal ["#7 r [open checks: not read yet]"], shown(links_for(plain, [], metadata: meta))
    refute links_for(plain, [], metadata: meta).first.key?(:group)
    assert_equal [], links_for(plain, [])
    bad = links_for(plain, [], metadata: { "prs" => [{ "url" => "#7", "role" => "pr" }] })
    assert_equal ["PRs [unknown]"], shown(bad)
    assert_match(/metadata prs has an entry that is no PR URL: /, detail(bad[0])["Why"])
  end

  def test_not_enrolled_flags_state_only_and_local_error_is_shown
    plain = { slug: "g/r", remote: "https://github.com/o/r.git", local_mode: nil, local_error: nil }
    @http.pulls = [pr(7, "o/r", draft: true)]
    meta = prs_meta("pr", "https://github.com/o/r/pull/7")
    links_for(plain, [], metadata: meta)
    @poller.run
    assert_equal ["#7 r [draft checks: not read yet]"], shown(links_for(plain, [], metadata: meta))
    broken = plain.merge(local_error: "guard.publicRemote names remote \"fork\", which has no URL")
    cfg = links_for(broken, [])
    assert_equal ["config [local unknown]"], shown(cfg)
    assert_equal ["/projects/g/r", 'guard.publicRemote names remote "fork", which has no URL'],
                 [cfg[0][:url], detail(cfg[0])["Why"]]
    assert_equal [], @flags.apply([], { id: 1 }, nil)
  end

  # a guard.mode the scanner refuses (local_mode nil + local_error): the assigned `pr` PR is still a row, beside the
  # config row that says why
  def test_a_bad_guard_mode_keeps_the_assigned_pr_row
    bad = { slug: "g/r", remote: "https://github.com/o/r.git", local_mode: nil,
            local_error: 'guard.mode is "mirror", not own or upstream', }
    meta = prs_meta("pr", "https://github.com/o/r/pull/7")
    links_for(bad, [], metadata: meta)
    @http.pulls = [pr(7, "o/r")]
    @poller.run
    rows = links_for(bad, [], metadata: meta)
    assert_equal ["#7 r [open checks: not read yet]", "config [local unknown]"], shown(rows)
    assert_equal 'guard.mode is "mirror", not own or upstream', detail(rows[1])["Why"]
  end

  # a PR stacked on another branch (or retargeted by hand) is a `base: <ref>` warning on its row; the
  # expected base is its side's (local → guard.localBranch, public → guard.publicBase's branch); an enrolment that
  # names no base says so on every read PR
  def test_a_pr_not_on_its_base_branch_is_flagged_and_gated
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/5", "public", "https://github.com/o/widgets/pull/12")
    links_for(ENROLLED, [], metadata: meta)
    @http.pulls = [pr(5, "o/widgets_local"), pr(12, "o/widgets", base: { "ref" => "feature/live-agent-status" })]
    @poller.run
    out = links_for(ENROLLED, [], metadata: meta)
    assert_equal ["#5 widgets_local [local open checks: not read yet]",
                  "#12 widgets [public open base: feature/live-agent-status checks: not read yet]",],
                 shown(out)
    assert_equal "warn", out[1][:tags][-2][:tone], "the base tag (the CI tag comes last)"
    assert_equal ["feature/live-agent-status", "main"], detail(out[1]).values_at("Base", "Expected base")
    assert_equal ["local", nil], detail(out[0]).values_at("Base", "Expected base")
    unknown = ENROLLED.merge(public_base: nil, local_error: "guard.publicBase is not set")
    out = links_for(unknown, [], metadata: meta)
    assert_equal "#12 widgets [public open base: feature/live-agent-status checks: not read yet]", shown(out)[1]
    assert_equal "unknown: guard.publicBase is not set", detail(out[1])["Expected base"]
    plain = { slug: "g/r", remote: "https://github.com/o/r.git", local_mode: nil, local_error: nil }
    @http.pulls = [pr(7, "o/r", base: { "ref" => "anything" })]
    links_for(plain, [], metadata: prs_meta("pr", "https://github.com/o/r/pull/7"))
    @poller.run
    plain_out = links_for(plain, [], metadata: prs_meta("pr", "https://github.com/o/r/pull/7"))
    assert_equal ["#7 r [open checks: not read yet]"], shown(plain_out), "a plain project's PR: any base"
    assert_equal "anything", detail(plain_out[0])["Base"]
  end

  # a PR on another enrolled project's repo is checked against THAT project's base, not the card's;
  # a repo no enrolment names (or two naming different bases) is an unknown expected base, said why
  def test_a_pr_on_another_projects_repo_is_flagged_against_that_projects_base
    @db[:projects].insert(slug: "g/eng", path: "/repos/eng", remote: "https://github.com/o/eng_local.git", own: true,
                          commits_window: 0, mine_window: 0, dirty: 0, scanned_at: 0, local_mode: "own",
                          local_repo: "https://github.com/o/eng_local.git", public_repo: "https://github.com/o/eng.git",
                          local_base: "main", public_base: "main")
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/5", "local", "https://github.com/o/eng_local/pull/7")
    links_for(ENROLLED, [], metadata: meta)
    @http.pulls = [pr(5, "o/widgets_local"), pr(7, "o/eng_local", base: { "ref" => "main" })]
    @poller.run
    out = links_for(ENROLLED, [], metadata: meta)
    assert_equal ["#5 widgets_local [local open checks: not read yet]", "#7 eng_local [local open checks: not read yet]"],
                 shown(out),
                 "the engine PR on main: its own project's base, no warning"
    @http.pulls = [pr(5, "o/widgets_local"), pr(7, "o/eng_local")]
    @now += 60
    @poller.run
    out = links_for(ENROLLED, [], metadata: meta)
    assert_equal "#7 eng_local [local open base: local checks: not read yet]", shown(out)[1]
    assert_equal %w[local main], detail(out[1]).values_at("Base", "Expected base")
    @db[:projects].where(slug: "g/eng").update(local_base: "develop", slug: "g/eng2")
    @db[:projects].insert(slug: "g/eng", path: "/repos/eng-b", remote: "https://github.com/o/eng_local.git", own: true,
                          commits_window: 0, mine_window: 0, dirty: 0, scanned_at: 0, local_mode: "own",
                          local_repo: "https://github.com/o/eng_local.git", local_base: "main")
    out = links_for(ENROLLED, [], metadata: meta)
    assert_equal "unknown: the enrolments of o/eng_local name different local bases: g/eng → main, g/eng2 → develop",
                 detail(out[1])["Expected base"]
    @db[:projects].where(slug: %w[g/eng g/eng2]).delete
    out = links_for(ENROLLED, [], metadata: meta)
    assert_equal "unknown: o/eng_local is the local repo of no enrolled project", detail(out[1])["Expected base"]
  end

  # GitHub's mergeable: false / dirty → conflicts, null (still computing) → "mergeable: computing" — never guessed clean
  # or conflicting; every other mergeable_state is GitHub's own word in the hover (blocked,
  # unstable and has_hooks are not "clean"); unstable / has_hooks carry no tag — the CI tag says what the checks
  # are; a value PrStates does not know → "unknown: <value>", never coerced; a merged or closed PR has none
  def test_mergeable_state_is_tagged_and_null_is_computing
    cases = { 1 => [{ mergeable: false, mergeable_state: "dirty" }, %w[conflicts bad], "conflicts"],
              2 => [{ mergeable: true, mergeable_state: "behind" }, %w[behind warn], "behind"],
              3 => [{ mergeable: nil, mergeable_state: "unknown" }, ["mergeable: computing", "muted"], "computing"],
              4 => [{ mergeable: true, mergeable_state: "unknown" }, ["mergeable: computing", "muted"], "computing"],
              5 => [{ mergeable: true, mergeable_state: "unstable" }, nil,
                    "unstable: a commit status is not success (pending counts) — see Checks",],
              6 => [{ mergeable: true, mergeable_state: "blocked" }, ["blocked by branch rules", "warn"],
                    "blocked: a branch rule is not met (a required review, or a required check not green yet)",],
              7 => [{ mergeable: true, mergeable_state: "has_hooks" }, nil,
                    "has_hooks: mergeable, statuses passing, the repo has pre-receive hooks",],
              8 => [{ mergeable: true, mergeable_state: "clean" }, nil, "clean"],
              9 => [{ mergeable: true, mergeable_state: "queued_somehow" }, ["unknown: queued_somehow", "warn"],
                    "unknown: queued_somehow",], }
    @http.pulls = cases.map { |n, (f, _, _)| pr(n, "o/widgets_local", **f) } +
                  [pr(10, "o/widgets_local", state: "closed", merged: "2026-11-08T11:00:00Z", mergeable: nil)]
    rows = lambda do
      (1..10).map { |n| links_for(ENROLLED, [], metadata: prs_meta("local", "https://github.com/o/widgets_local/pull/#{n}")).first }
    end
    rows.call
    @poller.run
    out = rows.call
    cases.each do |n, (_, want, mergeable)|
      tags = out[n - 1][:tags].drop(2).reject { |t| t[:text].start_with?("checks") }.map { |t| [t[:text], t[:tone]] }
      assert_equal [want].compact, tags, "PR #{n}"
      assert_equal mergeable, detail(out[n - 1])["Mergeable"], "PR #{n}"
    end
    assert_equal "#10 widgets_local [local merged]", shown([out[9]]).first, "merged: no mergeable tag"
    assert_nil detail(out[9])["Mergeable"]
  end

  # what the CI poller (CiChecks::Poller → gh_pr_checks pr:N) stored for an open PR, as it stores it
  def ci_row(n, state, repo: "o/widgets_local", detail: nil, head: "abc1234def", checked: @now, error: nil, requested: @now)
    @db[:gh_pr_checks].insert(repo: repo, ref: "pr:#{n}", requested_at: requested, checked_at: checked, number: n,
                              state: state, detail: detail, head: head, error: error)
  end

  def tags_of(link) = link[:tags].map { |t| [t[:text], t[:tone]] }

  # a PR showed "checks failing" while its only required check (jenkins/ci) was PENDING —
  # GitHub's mergeable_state "unstable" means "a commit status is not success", pending included. The rail's CI tag now
  # comes from the CI read the gates use (gh_pr_checks pr:N, required contexts only), one tag per state; GitHub's
  # unstable / has_hooks say nothing about checks the CI read does not say better, so they carry no tag
  def test_ci_tag_comes_from_the_ci_read_and_pending_is_never_failing
    cases = { 1 => ["pending", "running: jenkins/ci", ["checks running", "muted"]],
              2 => ["success", "passed: jenkins/ci", ["checks passed", "ok"]],
              3 => ["failure", "failed: jenkins/ci", ["checks failed", "bad"]],
              4 => ["stuck", "jenkins/ci pending since 2026-11-27T05:00:00Z, over ci.max_pending_minutes 60",
                    ["checks stuck", "bad"],],
              5 => ["nochecks", "required jenkins/ci not reported on abc1234", ["checks not reported", "warn"]], }
    @http.pulls = cases.keys.map { |n| pr(n, "o/widgets_local", mergeable_state: "unstable") }
    rows = -> { cases.keys.map { |n| links_for(ENROLLED, [], metadata: prs_meta("local", "https://github.com/o/widgets_local/pull/#{n}")).first } }
    rows.call
    @poller.run
    cases.each { |n, (state, det, _)| ci_row(n, state, detail: det) }
    out = rows.call
    cases.each do |n, (_, det, want)|
      tags = tags_of(out[n - 1])
      assert_equal [%w[local info], %w[open ok], want], tags, "PR #{n}"
      refute tags.any? { |t, _| t.include?("failing") }, "PR #{n}: never 'failing' from GitHub's unstable"
      assert_equal "#{det} · head abc1234", detail(out[n - 1])["Checks"], "PR #{n}"
      assert_match(/\(GitHub, ci.required checks\)\z/, detail(out[n - 1])["Checks read"], "PR #{n}")
      assert_equal "unstable: a commit status is not success (pending counts) — see Checks",
                   detail(out[n - 1])["Mergeable"], "PR #{n}"
    end
  end

  # the CI read's own gaps are said as gaps, never as a pass or a failure
  def test_ci_tag_unread_stale_failed_and_unconfigured
    meta = ->(n) { prs_meta("local", "https://github.com/o/widgets_local/pull/#{n}") }
    @http.pulls = (1..4).map { |n| pr(n, "o/widgets_local") }
    (1..4).each { |n| links_for(ENROLLED, [], metadata: meta.call(n)) }
    @poller.run
    first = links_for(ENROLLED, [], metadata: meta.call(1)).first
    assert_equal ["checks: not read yet", "muted"], tags_of(first).last, "no CI row yet: asked now, never green or red"
    assert_equal 1, @db[:gh_pr_checks].where(repo: "o/widgets_local", ref: "pr:1").count, "the view asks the CI poller"
    ci_row(2, "success", checked: @now - 400, requested: @now - 10) # wanted, but the service stopped answering
    ci_row(3, nil, checked: nil,
           error: "no required CI contexts for o/widgets_local: config/busyyaks.yml ci.required does not list it")
    ci_row(4, "success", checked: @now - 5000, requested: @now - 5000) # nobody looked for a while: asked again
    out = (2..4).map { |n| links_for(ENROLLED, [], metadata: meta.call(n)).first }
    assert_equal ["checks: unknown", "warn"], tags_of(out[0]).last
    assert_match(/is 400s old \(github service stopped\?\)/, detail(out[0])["Checks"])
    assert_equal ["checks: unknown", "warn"], tags_of(out[1]).last
    assert_match(/ci.required does not list it/, detail(out[1])["Checks"])
    assert_equal ["checks: not read yet", "muted"], tags_of(out[2]).last, "an old answer nobody wanted is not shown"
  end

  # a view that re-asks an old answer nobody wanted clears it the way the gates do
  # (PrStates.ci_read, shared with CiChecks::Port#answer) — a second view before the poller runs, and the gate's read,
  # see "not read yet" / unpolled, never "stopped?" from the row the view itself just touched
  def test_a_second_view_of_a_re_asked_answer_is_still_unread_and_the_gate_reads_it_unpolled
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/1")
    @http.pulls = [pr(1, "o/widgets_local")]
    links_for(ENROLLED, [], metadata: meta)
    @poller.run
    ci_row(1, "success", checked: @now - 5000, requested: @now - 5000)
    2.times do |i|
      link = links_for(ENROLLED, [], metadata: meta).first
      assert_equal ["checks: not read yet", "muted"], tags_of(link).last, "view #{i + 1}"
    end
    row = @db[:gh_pr_checks].where(repo: "o/widgets_local", ref: "pr:1").first
    assert_equal [nil, nil, @now], row.values_at(:checked_at, :error, :requested_at), "cleared for the poller"
    assert_equal [:unread], PS.ci_read(@db, "o/widgets_local", "pr:1", now: @now, wanted_for: 600, stale_after: 180),
                 "the gate's read (CiChecks::Port#answer → unpolled)"
  end

  # a push between the two polls — the CI row answers the OLD head, the PR-state row has the new one:
  # not this head's checks, never the old pass (or failure); the hover names both shas. Same head → the CI tag.
  def test_a_ci_answer_for_another_head_is_not_read_yet
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/1")
    @http.pulls = [pr(1, "o/widgets_local").merge("head" => { "sha" => "def5678aaa", "ref" => "card/1", "repo" => {} })]
    links_for(ENROLLED, [], metadata: meta)
    @poller.run
    assert_equal "def5678aaa", @db[:gh_pr_states].where(ref: "pr:1").get(:head), "the head sha is kept"
    page = @db[:gh_pages].where(url: PS::Poller.cache_key("/repos/o/widgets_local/pulls/1")).first
    assert_equal({ "sha" => "def5678aaa" }, JSON.parse(page[:items])["head"], "the head's sha only, never its repo")
    ci_row(1, "success", detail: "passed: jenkins/ci", head: "abc1234def")
    link = links_for(ENROLLED, [], metadata: meta).first
    assert_equal ["checks: not read yet", "muted"], tags_of(link).last
    refute tags_of(link).any? { |t, _| t == "checks passed" }, "the old head's green is not this head's"
    assert_equal "read on abc1234, the PR's head is now def5678 — waiting for the github service", detail(link)["Checks"]
    @db[:gh_pr_checks].where(ref: "pr:1").update(head: "def5678aaa")
    assert_equal ["checks passed", "ok"], tags_of(links_for(ENROLLED, [], metadata: meta).first).last, "same head"
  end

  # "informational check failed" only beside a green — the poller writes its note on pending and red
  # rows too, where the CI tag already says the checks are not green; behind + pending and dirty + red keep both tags
  def test_informational_tag_only_beside_green_and_combined_states
    @http.pulls = [pr(1, "o/widgets_local", mergeable_state: "behind"),
                   pr(2, "o/widgets_local", mergeable: false, mergeable_state: "dirty"),]
    meta = ->(n) { prs_meta("local", "https://github.com/o/widgets_local/pull/#{n}") }
    (1..2).each { |n| links_for(ENROLLED, [], metadata: meta.call(n)) }
    @poller.run
    ci_row(1, "pending", detail: "running: jenkins/ci; #{PS::INFORMATIONAL_NOTE}lint-docs")
    ci_row(2, "failure", detail: "failed: jenkins/ci; #{PS::INFORMATIONAL_NOTE}lint-docs")
    behind, dirty = (1..2).map { |n| links_for(ENROLLED, [], metadata: meta.call(n)).first }
    assert_equal [%w[local info], %w[open ok], %w[behind warn], ["checks running", "muted"]], tags_of(behind)
    assert_equal [%w[local info], %w[open ok], %w[conflicts bad], ["checks failed", "bad"]], tags_of(dirty)
    assert_match(/#{PS::INFORMATIONAL_NOTE}lint-docs/, detail(behind)["Checks"], "said in the hover")
  end

  # required checks green but an informational check red → both said; a merged / closed PR has no CI tag;
  # GitHub not connected → no CI tag beyond the state's own error
  def test_ci_tag_informational_red_and_no_tag_on_merged_or_closed
    @http.pulls = [pr(1, "o/widgets_local"), pr(2, "o/widgets_local", state: "closed", merged: "2026-11-08T10:00:00Z"),
                   pr(3, "o/widgets_local", draft: true),]
    meta = ->(n) { prs_meta("local", "https://github.com/o/widgets_local/pull/#{n}") }
    (1..3).each { |n| links_for(ENROLLED, [], metadata: meta.call(n)) }
    @poller.run
    ci_row(1, "success", detail: "passed: jenkins/ci; #{PS::INFORMATIONAL_NOTE}lint-docs") # the poller's note
    ci_row(3, "failure", detail: "failed: jenkins/ci")
    one, two, three = (1..3).map { |n| links_for(ENROLLED, [], metadata: meta.call(n)).first }
    assert_equal [["checks passed", "ok"], ["informational check failed", "warn"]], tags_of(one).last(2)
    assert_equal [%w[local info], %w[merged done]], tags_of(two), "merged: no CI tag"
    assert_nil detail(two)["Checks"]
    assert_equal [%w[local info], %w[draft muted], ["checks failed", "bad"]], tags_of(three), "draft + red"
  end

  # GitHub's has_hooks = mergeable, statuses passing, pre-receive hooks exist — it was tagged "hooks pending";
  # blocked keeps its tag and says which rules can block
  def test_has_hooks_is_not_pending_and_blocked_says_why
    @http.pulls = [pr(1, "o/widgets_local", mergeable_state: "has_hooks"), pr(2, "o/widgets_local", mergeable_state: "blocked")]
    meta = ->(n) { prs_meta("local", "https://github.com/o/widgets_local/pull/#{n}") }
    (1..2).each { |n| links_for(ENROLLED, [], metadata: meta.call(n)) }
    @poller.run
    ci_row(1, "success", detail: "passed: jenkins/ci")
    ci_row(2, "pending", detail: "running: jenkins/ci")
    hooks, blocked = (1..2).map { |n| links_for(ENROLLED, [], metadata: meta.call(n)).first }
    refute tags_of(hooks).any? { |t, _| t.include?("hooks") }
    assert_equal "has_hooks: mergeable, statuses passing, the repo has pre-receive hooks", detail(hooks)["Mergeable"]
    assert_includes tags_of(blocked), ["blocked by branch rules", "warn"]
    assert_equal "blocked: a branch rule is not met (a required review, or a required check not green yet)",
                 detail(blocked)["Mergeable"]
    assert_nil detail(blocked)["Blocked by"], "checks still running: either rule may block"
    ci_row(3, "success", detail: "passed: jenkins/ci")
    @http.pulls << pr(3, "o/widgets_local", mergeable_state: "blocked")
    links_for(ENROLLED, [], metadata: meta.call(3))
    @now += 60
    @poller.run
    @db[:gh_pr_checks].where(ref: "pr:3").update(checked_at: @now)
    green = links_for(ENROLLED, [], metadata: meta.call(3)).first
    assert_equal "ci.required checks green — GitHub's block is another rule: a review, a ruleset, or a required " \
                 "check outside ci.required", detail(green)["Blocked by"],
                 "REST has no review decision, and GitHub's required list may differ from ci.required"
  end

  # every GitHub mergeable_state maps to itself or to what it means; nothing unknown is coerced
  def test_merge_state_names_every_github_value
    { [true, "clean"] => "clean", [true, "behind"] => "behind", [true, "blocked"] => "blocked",
      [true, "unstable"] => "unstable", [true, "has_hooks"] => "has_hooks", [true, "draft"] => "draft",
      [false, "dirty"] => "conflicts", [true, "dirty"] => "conflicts", [false, "blocked"] => "conflicts",
      [nil, "clean"] => "computing", [true, "unknown"] => "computing",
      [true, "new_value"] => "unknown: new_value", [true, nil] => "unknown: none given", }.each do |(m, st), want|
      assert_equal want, Busyyaks::PrStates.merge_state("mergeable" => m, "mergeable_state" => st), [m, st].inspect
    end
  end

  # auto-merge on: GitHub merges once the checks pass, whatever the board says — a warning on the row
  def test_auto_merge_is_tagged
    meta = prs_meta("local", "https://github.com/o/widgets_local/pull/5")
    @http.pulls = [pr(5, "o/widgets_local", auto_merge: { "merge_method" => "squash", "enabled_by" => { "login" => "x" } })]
    links_for(ENROLLED, [], metadata: meta)
    @poller.run
    out = links_for(ENROLLED, [], metadata: meta)
    assert_equal ["#5 widgets_local [local open auto-merge checks: not read yet]"], shown(out)
    assert_equal "warn", out[0][:tags][-2][:tone], "the auto-merge tag (the CI tag comes last)"
    assert_match(/without the board's approval/, detail(out[0])["Auto-merge"])
    @http.pulls = [pr(5, "o/widgets_local")]
    @poller.run
    assert_equal ["#5 widgets_local [local open checks: not read yet]"], shown(links_for(ENROLLED, [], metadata: meta)),
                 "turned off: no tag"
  end
end
