# frozen_string_literal: true

require "test_helper"
require "busyyaks/pr_states"

# PR flags — Poller (github side) + Reader (web side) over gh_pr_states, and the links they flag.
class PrStatesTest < Minitest::Test
  include DBReset
  PS = Busyyaks::PrStates

  class FakeHttp
    attr_accessor :pulls, :requests, :fail
    def initialize = (@requests = []; @pulls = [])
    def get(url, headers)
      raise "no token" unless headers["Authorization"]
      @requests << url
      return [401, {}, "{\"message\":\"Bad credentials\"}"] if @fail

      body = case url
             when %r{/pulls\?state=all&head=([^&]+)}
               head = URI.decode_www_form_component(Regexp.last_match(1))
               @pulls.select { |p| p["head_label"] == head }
             when %r{/pulls/(\d+)\z} then @pulls.find { |p| p["number"] == Regexp.last_match(1).to_i }
             end
      return [404, {}, "{\"message\":\"Not Found\"}"] if body.nil?

      [200, {}, JSON.generate(body)]
    end
  end

  def pr(n, repo, state: "open", draft: false, merged: nil, head: nil)
    { "number" => n, "state" => state, "draft" => draft, "merged_at" => merged,
      "html_url" => "https://github.com/#{repo}/pull/#{n}", "head_label" => head, }
  end

  def setup
    super
    @db = Hanami.app["db.gateway"].connection
    @now = 1_000_000
    @http = FakeHttp.new
    client = Busyyaks::GithubNetwork::Client.new(token: "t", http: @http)
    @poller = PS::Poller.new(db: @db, client: client, wanted_for: 600, clock: -> { @now })
    @reader = PS::Reader.new(db: @db, stale_after: 180, wanted_for: 600, clock: -> { @now })
    @flags = PS::Flags.new(@reader)
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
             public_head: "https://github.com/o/widgets.git", local_error: nil, }.freeze

  # "label [tag tag]" — what the rail shows
  def shown(links) = links.map { |l| l[:tags] ? "#{l[:label]} [#{l[:tags].map { |t| t[:text] }.join(' ')}]" : l[:label] }
  def detail(link) = link[:detail].to_h { |r| [r[:label], r[:value]] }

  PUB12 = { "prs" => { "public" => "https://github.com/o/widgets/pull/12" } }.freeze

  def links_for(project, links, id: 158, metadata: nil)
    @flags.apply(links, { id: id, metadata: metadata }, project)
  end

  # the PRs assigned to the card (metadata prs.local / prs.public) are its PR rows, flagged with role + state
  def test_enrolled_project_flags_local_and_public_prs_with_their_state
    links = [{ kind: "repo", label: "g/widgets", url: "https://github.com/o/widgets_local" }]
    both = { "prs" => PUB12["prs"].merge("local" => "https://github.com/o/widgets_local/pull/5") }
    first = links_for(ENROLLED, links, metadata: both)
    assert_equal ["g/widgets", "#5 [local checking]", "#12 [public checking]"], shown(first)
    assert_equal "waiting for the github service", detail(first[1])["Read"]
    assert_equal [%w[o/widgets pr:12], %w[o/widgets_local pr:5]],
                 @db[:gh_pr_states].order(:repo).select_map(%i[repo ref]), "by number, never by a branch name"
    @http.pulls = [pr(5, "o/widgets_local", state: "closed", merged: "2026-11-08T11:00:00Z"),
                   pr(12, "o/widgets", head: "o:fix/scanner-skips-worktrees"),]
    @poller.run
    out = links_for(ENROLLED, links, metadata: both)
    assert_equal ["#5 [local merged]", "#12 [public open]"], shown(out.drop(1))
    assert_equal [%w[local info], %w[merged done]], out[1][:tags].map { |t| t.values_at(:text, :tone) }
    assert_equal({ "Repo" => "o/widgets_local", "Role" => "private local repo", "State" => "merged",
                   "Read" => "#{Time.at(@now).strftime('%Y-%m-%d %H:%M:%S %Z')} (GitHub)", },
                 detail(out[1]))
    @now += 30
    assert_equal out, links_for(ENROLLED, links, metadata: both),
                 "no clock in the JSON: the card rev changes only with a new GitHub read"
    assert_equal "public repo", detail(out[2])["Role"]
    assert_equal "https://github.com/o/widgets/pull/12", out.last[:url]
    assert_equal %w[repo pr pr], out.map { |l| l[:kind] }
  end

  # no PR assigned → no row and nothing asked (a placeholder is not a pull request, a branch name is not guessed); the
  # same PR pasted as a URL stays a plain link beside its row
  def test_no_public_pr_recorded_shows_no_row_and_a_pasted_url_stays_a_link
    assert_equal [], links_for(ENROLLED, [])
    assert_equal [], links_for(ENROLLED, [], metadata: { "prs" => {} })
    assert_equal [], @db[:gh_pr_states].select_map(:ref)
    @http.pulls = [pr(12, "o/widgets")]
    listed = [{ kind: "url", label: "github.com/o/widgets/pull/12", url: "https://github.com/o/widgets/pull/12" }]
    links_for(ENROLLED, listed, metadata: PUB12)
    @poller.run
    out = links_for(ENROLLED, listed, metadata: PUB12)
    assert_equal ["github.com/o/widgets/pull/12", "#12 [public open]"], shown(out)
    assert_equal %w[url pr], out.map { |l| l[:kind] }
    assert_equal ["github.com/o/widgets/pull/12"], shown(links_for(ENROLLED, listed)), "a pasted URL is not a PR row"
  end

  # review round 1: a raw `cards` row carries metadata as JSON text (the engine's watch pass, waiting counts)
  def test_assigned_reads_a_raw_rows_json_metadata
    assert_equal ["o/widgets", 12], PS.assigned({ id: 158, metadata: JSON.generate(PUB12) }, "public", "o/widgets")
    assert_nil PS.assigned({ id: 158, metadata: nil }, "public", "o/widgets")
    assert_nil PS.assigned({ id: 158, metadata: PUB12 }, "local", "o/widgets"), "by role"
    mixed = { "prs" => { "public" => "https://github.com/O/Widgets/pull/12" } }
    assert_equal ["o/widgets", 12], PS.assigned({ id: 158, metadata: mixed }, "public", "o/widgets"), "owner/name in any case"
    e = assert_raises(PS::Invalid) { PS.assigned({ id: 158, metadata: "{nope" }, "public", "o/widgets") }
    assert_match(/\Acard #158 metadata is not JSON: /, e.message)
  end

  # a prs.public that is no PR of the public repo is said on the card, never followed
  def test_a_public_pr_on_another_repo_is_said
    out = links_for(ENROLLED, [], metadata: { "prs" => { "public" => "https://github.com/o/widgets_local/pull/5" } })
    assert_equal ["public [public unknown]"], shown(out)
    assert_match(/card #158 metadata prs.public is not a PR on o\/widgets: /, detail(out[0])["Why"])
    assert_equal [], @db[:gh_pr_states].select_map(:ref)
  end

  # upstream mode with no readable public repo — roles still known, the public PR said unknown with the reason
  def test_an_unreadable_public_repo_keeps_the_roles_and_says_why
    up = ENROLLED.merge(local_mode: "upstream", public_repo: nil, public_head: nil,
                        local_error: 'guard.upstream names remote "upstream", which has no URL')
    out = links_for(up, [], id: 9, metadata: { "prs" => { "local" => "https://github.com/o/widgets_local/pull/3" } })
    assert_equal ["#3 [local checking]", "public [public unknown]"], shown(out)
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
    assert_equal ["github.com/o/widgets/pull/4", "#12 [public open]"], shown(links_for(ENROLLED, named, metadata: PUB12))
    assert_equal [%w[o/widgets pr:12]], @db[:gh_pr_states].select_map(%i[repo ref]), "the pasted PR is not read"
  end

  # on a live board, "engine PR #63" and "public PR #13" in comments became #63 / #13 [local] rows on the
  # card's own repo. A PR number in the text and the handoff pr_url are never rows: the rows are the assigned PRs
  def test_text_pr_refs_and_the_handoff_pr_are_never_rows
    meta = { "prs" => { "local" => "https://github.com/o/widgets_local/pull/139" } }
    text = [{ kind: "pr", label: "#139", url: "https://github.com/o/widgets_local/pull/139" }, # the handoff pr_url
            { kind: "pr", label: "#63", url: "https://github.com/o/widgets_local/pull/63" },   # "engine PR #63"
            { kind: "pr", label: "#13", url: "https://github.com/o/widgets_local/pull/13" },]  # "public PR #13"
    assert_equal ["#139 [local checking]"], shown(links_for(ENROLLED, text, metadata: meta))
    assert_equal [%w[o/widgets_local pr:139]], @db[:gh_pr_states].select_map(%i[repo ref]), "#63 / #13 are not read"
    assert_equal [], links_for(ENROLLED, text), "nothing assigned → no PR row at all"
    plain = { slug: "g/r", remote: "https://github.com/o/r.git", local_mode: nil, local_error: nil }
    assert_equal [], links_for(plain, [{ kind: "pr", label: "#7", url: "https://github.com/o/r/pull/7" }])
    assert_equal [], @flags.apply(text, { id: 1 }, nil), "no project: no PR rows either"
  end

  def test_upstream_mode_reads_the_public_pr_on_the_upstream_repo
    up = ENROLLED.merge(local_mode: "upstream", public_repo: "https://github.com/ruby/ruby.git",
                        public_head: "https://github.com/me/ruby.git")
    links_for(up, [], id: 9, metadata: { "prs" => { "public" => "https://github.com/ruby/ruby/pull/77" } })
    assert_equal [%w[ruby/ruby pr:77]], @db[:gh_pr_states].select_map(%i[repo ref])
  end

  # the local PR assigned to the card is listed with no text naming it; a branch is never looked up
  def test_the_assigned_local_pr_is_listed_without_text
    meta = { "prs" => { "local" => "https://github.com/o/widgets_local/pull/45" } }
    assert_equal ["#45 [local checking]"], shown(links_for(ENROLLED, [], metadata: meta))
    @http.pulls = [pr(45, "o/widgets_local")]
    @poller.run
    branch = { kind: "branch", label: "card/158-a", url: "https://github.com/o/widgets_local/tree/card/158-a" }
    out = links_for(ENROLLED, [branch], metadata: meta)
    assert_equal ["card/158-a", "#45 [local open]"], shown(out)
    assert_equal [%w[o/widgets_local pr:45]], @db[:gh_pr_states].select_map(%i[repo ref]), "the branch is not looked up"
    bad = links_for(ENROLLED, [], metadata: { "prs" => { "local" => "https://github.com/o/widgets/pull/12" } })
    assert_equal ["local [local unknown]"], shown(bad)
    assert_match(/metadata prs.local is not a PR on o\/widgets_local: /, detail(bad[0])["Why"])
  end

  # a plain project's card: its `pr` PR on the repo its URL names, no role tag
  def test_a_plain_projects_assigned_pr_has_no_role
    plain = { slug: "g/r", path: "/repos/r", remote: "https://github.com/o/r.git", pr_remote: "https://github.com/o/r.git",
              local_mode: nil, local_error: nil, }
    meta = { "prs" => { "pr" => "https://github.com/o/r/pull/7" } }
    links_for(plain, [], metadata: meta)
    @http.pulls = [pr(7, "o/r")]
    @poller.run
    assert_equal ["#7 [open]"], shown(links_for(plain, [], metadata: meta))
    assert_equal [], links_for(plain, [])
    assert_equal ["#7 [open]"], shown(links_for(plain.merge(pr_remote: nil), [], metadata: meta)), "any repo"
    bad = links_for(plain, [], metadata: { "prs" => { "pr" => "#7" } })
    assert_equal ["pr [unknown]"], shown(bad)
    assert_match(/metadata prs.pr is not a PR on github.com: /, detail(bad[0])["Why"])
  end

  def test_not_enrolled_flags_state_only_and_local_error_is_shown
    plain = { slug: "g/r", remote: "https://github.com/o/r.git", local_mode: nil, local_error: nil }
    @http.pulls = [pr(7, "o/r", draft: true)]
    meta = { "prs" => { "pr" => "https://github.com/o/r/pull/7" } }
    links_for(plain, [], metadata: meta)
    @poller.run
    assert_equal ["#7 [draft]"], shown(links_for(plain, [], metadata: meta))
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
    meta = { "prs" => { "pr" => "https://github.com/o/r/pull/7" } }
    links_for(bad, [], metadata: meta)
    @http.pulls = [pr(7, "o/r")]
    @poller.run
    rows = links_for(bad, [], metadata: meta)
    assert_equal ["#7 [open]", "config [local unknown]"], shown(rows)
    assert_equal 'guard.mode is "mirror", not own or upstream', detail(rows[1])["Why"]
  end
end
