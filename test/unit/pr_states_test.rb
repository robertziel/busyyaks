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
    @branches = {} # repo path → its branches (Kanban.git_port, the scanner's last read, in production)
    @flags = PS::Flags.new(@reader, branches: ->(project) { @branches.fetch(project[:path]) })
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

  def test_head_lookup_finds_the_public_pr_or_none
    @reader.lookup("o/p", "head:o:fix/settings-toggle")
    @reader.lookup("o/p", "head:o:feature/board-filter")
    @http.pulls = [pr(12, "o/p", head: "o:fix/settings-toggle")]
    @poller.run
    assert_equal({ state: "open", number: 12, url: "https://github.com/o/p/pull/12", checked_at: @now },
                 @reader.lookup("o/p", "head:o:fix/settings-toggle"))
    assert_equal "none", @reader.lookup("o/p", "head:o:feature/board-filter")[:state]
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
    @branches[project[:path]] ||= Set.new if project && project[:path]
    @flags.apply(links, { id: id, metadata: metadata }, project)
  end

  # the public PR is the card's metadata prs.public (git mirror-publish names its branch after the change, not the card)
  def test_enrolled_project_flags_local_and_public_prs_with_their_state
    links = [{ kind: "repo", label: "g/widgets", url: "https://github.com/o/widgets_local" },
             { kind: "pr", label: "#5", url: "https://github.com/o/widgets_local/pull/5" },]
    first = links_for(ENROLLED, links, metadata: PUB12)
    assert_equal ["g/widgets", "#5 [local checking]", "#12 [public checking]"], shown(first)
    assert_equal "waiting for the github service", detail(first[1])["Read"]
    assert_equal [%w[o/widgets pr:12], %w[o/widgets_local pr:5]],
                 @db[:gh_pr_states].order(:repo).select_map(%i[repo ref]), "by number, never by a branch name"
    @http.pulls = [pr(5, "o/widgets_local", state: "closed", merged: "2026-11-08T11:00:00Z"),
                   pr(12, "o/widgets", head: "o:fix/scanner-skips-worktrees"),]
    @poller.run
    out = links_for(ENROLLED, links, metadata: PUB12)
    assert_equal ["#5 [local merged]", "#12 [public open]"], shown(out.drop(1))
    assert_equal [%w[local info], %w[merged done]], out[1][:tags].map { |t| t.values_at(:text, :tone) }
    assert_equal({ "Repo" => "o/widgets_local", "Role" => "private local repo", "State" => "merged",
                   "Read" => "#{Time.at(@now).strftime('%Y-%m-%d %H:%M:%S %Z')} (GitHub)", },
                 detail(out[1]))
    @now += 30
    assert_equal out, links_for(ENROLLED, links, metadata: PUB12),
                 "no clock in the JSON: the card rev changes only with a new GitHub read"
    assert_equal "public repo", detail(out[2])["Role"]
    assert_equal "https://github.com/o/widgets/pull/12", out.last[:url]
    assert_equal %w[repo pr pr], out.map { |l| l[:kind] }
  end

  # no public PR recorded → no row and nothing asked (a placeholder is not a pull request, a branch name is not
  # guessed); one the text already lists is not repeated
  def test_no_public_pr_recorded_shows_no_row_and_a_listed_one_is_not_duplicated
    assert_equal [], links_for(ENROLLED, [])
    assert_equal [], links_for(ENROLLED, [], metadata: { "prs" => { "local" => "x" } })
    assert_equal [], @db[:gh_pr_states].select_map(:ref)
    @http.pulls = [pr(12, "o/widgets")]
    listed = [{ kind: "url", label: "github.com/o/widgets/pull/12", url: "https://github.com/o/widgets/pull/12" }]
    links_for(ENROLLED, listed, metadata: PUB12)
    @poller.run
    assert_equal ["#12 [public open]"], shown(links_for(ENROLLED, listed, metadata: PUB12))
    assert_equal ["pr"], links_for(ENROLLED, listed, metadata: PUB12).map { |l| l[:kind] }
  end

  # review round 1: a raw `cards` row carries metadata as JSON text (the engine's watch pass, waiting counts)
  def test_public_pr_reads_a_raw_rows_json_metadata
    assert_equal ["o/widgets", 12], PS.public_pr({ id: 158, metadata: JSON.generate(PUB12) }, "o/widgets")
    assert_nil PS.public_pr({ id: 158, metadata: nil }, "o/widgets")
    mixed = { "prs" => { "public" => "https://github.com/O/Widgets/pull/12" } }
    assert_equal ["o/widgets", 12], PS.public_pr({ id: 158, metadata: mixed }, "o/widgets"), "owner/name in any case"
    e = assert_raises(PS::Invalid) { PS.public_pr({ id: 158, metadata: "{nope" }, "o/widgets") }
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
    out = links_for(up, [{ kind: "pr", label: "#3", url: "https://github.com/o/widgets_local/pull/3" }], id: 9)
    assert_equal ["#3 [local checking]", "public [public unknown]"], shown(out)
    assert_equal 'guard.upstream names remote "upstream", which has no URL', detail(out.last)["Why"]
    assert_equal "warn", out.last[:tags].last[:tone]
    assert_equal "/projects/g/widgets", out.last[:url]
  end

  # review: another PR of the public repo named in the text (background, a follow-up) does not hide the card's own
  def test_another_public_pr_in_the_text_keeps_the_cards_own_public_row
    @http.pulls = [pr(4, "o/widgets"), pr(12, "o/widgets")]
    named = [{ kind: "url", label: "github.com/o/widgets/pull/4", url: "https://github.com/o/widgets/pull/4" }]
    links_for(ENROLLED, named, metadata: PUB12)
    @poller.run
    assert_equal ["#4 [public open]", "#12 [public open]"], shown(links_for(ENROLLED, named, metadata: PUB12))
  end

  def test_upstream_mode_reads_the_public_pr_on_the_upstream_repo
    up = ENROLLED.merge(local_mode: "upstream", public_repo: "https://github.com/ruby/ruby.git",
                        public_head: "https://github.com/me/ruby.git")
    links_for(up, [], id: 9, metadata: { "prs" => { "public" => "https://github.com/ruby/ruby/pull/77" } })
    assert_equal [%w[ruby/ruby pr:77]], @db[:gh_pr_states].select_map(%i[repo ref])
  end

  # before the handoff names it, the local PR opened from the card's branch (card/<id>-*, in the repo) is
  # found on GitHub by its head and listed with its state; nothing is listed while GitHub has not answered
  def test_the_pr_opened_from_the_cards_branch_is_listed_before_the_handoff
    @branches["/repos/widgets"] = Set["main", "card/158-gate-files", "card/7-other", "fix/settings-toggle"]
    assert_equal [], links_for(ENROLLED, []), "asked, not answered: no row"
    assert_equal [%w[o/widgets_local head:o:card/158-gate-files]],
                 @db[:gh_pr_states].order(:repo, :ref).select_map(%i[repo ref]),
                 "the card's own branch only — not main, not another card's, not a branch the text does not name"
    @http.pulls = [pr(45, "o/widgets_local", head: "o:card/158-gate-files"), pr(3, "o/widgets_local", head: "o:card/7-other")]
    @poller.run
    out = links_for(ENROLLED, [])
    assert_equal ["#45 [local open]"], shown(out)
    assert_equal({ "Repo" => "o/widgets_local", "Role" => "private local repo", "Branch" => "o:card/158-gate-files",
                   "State" => "open",
                   "Read" => "#{Time.at(@now).strftime("%Y-%m-%d %H:%M:%S %Z")} (GitHub)", },
                 detail(out[0]))
    assert_equal ["https://github.com/o/widgets_local/pull/45", "pr"], [out[0][:url], out[0][:kind]]
  end

  # a branch the card's text names (the engine's branch link) is looked up too; the PR the handoff / text already lists
  # is not repeated
  def test_a_named_branch_is_looked_up_and_a_listed_pr_is_not_duplicated
    @branches["/repos/widgets"] = Set["main", "feat/x", "card/158-a"]
    named = [{ kind: "branch", label: "feat/x", url: "https://github.com/o/widgets_local/tree/feat/x" },
             { kind: "branch", label: "main", url: "https://github.com/o/widgets_local/tree/main" },]
    links_for(ENROLLED, named)
    @http.pulls = [pr(8, "o/widgets_local", head: "o:feat/x", draft: true), pr(45, "o/widgets_local", head: "o:card/158-a")]
    @poller.run
    assert_equal ["feat/x", "main", "#45 [local open]", "#8 [local draft]"], shown(links_for(ENROLLED, named))
    assert_equal "none", @reader.lookup("o/widgets_local", "head:o:main")[:state], "main has no PR: no row"
    # the handoff / text names it now
    with_pr = named + [{ kind: "pr", label: "#45", url: "https://github.com/o/widgets_local/pull/45" }]
    links_for(ENROLLED, with_pr)
    @poller.run
    assert_equal ["feat/x", "main", "#45 [local open]", "#8 [local draft]"], shown(links_for(ENROLLED, with_pr))
    assert_equal 1, links_for(ENROLLED, with_pr).count { |l| l[:url] == "https://github.com/o/widgets_local/pull/45" }
  end

  # a failed head read is said on a row, never hidden (no fallback); a plain project's branch PR has no role tag
  def test_a_failed_branch_lookup_is_said_and_a_plain_projects_branch_pr_has_no_role
    plain = { slug: "g/r", path: "/repos/r", remote: "https://github.com/o/r.git", pr_remote: "https://github.com/o/r.git",
              local_mode: nil, local_error: nil, }
    @branches["/repos/r"] = Set["card/158-x"]
    links_for(plain, [])
    @http.fail = true
    @poller.run
    bad = links_for(plain, [])
    assert_equal ["card/158-x [unknown]"], shown(bad)
    assert_match(/GitHub read failed: .*401/, detail(bad[0])["Why"])
    assert_equal "https://github.com/o/r/pulls?q=is%3Apr+head%3Acard%2F158-x", bad[0][:url]
    @http.fail = false
    @http.pulls = [pr(7, "o/r", head: "o:card/158-x")]
    @poller.run
    assert_equal ["#7 [open]"], shown(links_for(plain, []))
    assert_equal [], links_for(plain.merge(path: nil), []), "no checkout to read branches from: nothing to look up"
  end

  def test_not_enrolled_flags_state_only_and_local_error_is_shown
    plain = { slug: "g/r", remote: "https://github.com/o/r.git", local_mode: nil, local_error: nil }
    @http.pulls = [pr(7, "o/r", draft: true)]
    links_for(plain, [{ kind: "pr", label: "#7", url: "https://github.com/o/r/pull/7" }])
    @poller.run
    assert_equal ["#7 [draft]"], shown(links_for(plain, [{ kind: "pr", label: "#7", url: "https://github.com/o/r/pull/7" }]))
    broken = plain.merge(local_error: "guard.publicRemote names remote \"fork\", which has no URL")
    cfg = links_for(broken, [])
    assert_equal ["config [local unknown]"], shown(cfg)
    assert_equal ["/projects/g/r", 'guard.publicRemote names remote "fork", which has no URL'],
                 [cfg[0][:url], detail(cfg[0])["Why"]]
    assert_equal [], @flags.apply([], { id: 1 }, nil)
  end
end
