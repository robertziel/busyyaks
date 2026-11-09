# frozen_string_literal: true

require "test_helper"
require_relative "../support/fake_github"
require "busyyaks/github_network"

# The dashboard feed (received_events): collection, the feed part of github_network's data, the tl:github feed section
# and its check_report provenance.
class GithubFeedTest < Minitest::Test
  include DBReset
  GN = Busyyaks::GithubNetwork
  NOW = Time.utc(2026, 11, 2, 12).to_i
  FEED = "/users/me/received_events?per_page=100"
  AV = "https://avatars.githubusercontent.com/u/7?v=4"

  def setup
    super
    @gh = FakeGithub.new
    @now = NOW
    @data = GN::Data.default
    @gh.set("/users/me", { "login" => "me", "id" => 1 })
    @gh.set("/users/me/following?per_page=100&page=1", [])
    @gh.set("/repos/alice/new-tool", { "id" => 5, "full_name" => "alice/new-tool", "html_url" => "https://github.com/alice/new-tool",
                                       "description" => "A new tool", "language" => "Go", "stargazers_count" => 12,
                                       "topics" => ["cli"], "owner" => { "avatar_url" => AV }, })
  end

  def ev(id, type, actor, repo, hours_ago, payload = {})
    { "id" => id.to_s, "type" => type,
      "actor" => { "login" => actor, "avatar_url" => "https://avatars.githubusercontent.com/u/#{actor.sum}?" },
      "repo" => { "name" => repo }, "payload" => payload, "public" => true,
      "created_at" => Time.at(@now - (hours_ago * 3600)).utc.iso8601, }
  end

  def day1
    release = { "tag_name" => "v1.2.0", "name" => "Lib 1.2",
                "html_url" => "https://github.com/alice/lib/releases/tag/v1.2.0", }
    # the push: a higher id range, older
    [ev(25_000_000_002, "PushEvent", "bot", "bot/data", 3, { "ref" => "refs/heads/a", "head" => "h1" }),
     ev(18_000_000_010, "ReleaseEvent", "alice", "alice/lib", 1, { "action" => "published", "release" => release }),
     ev(18_000_000_009, "CreateEvent", "alice", "alice/lib", 1, { "ref_type" => "tag", "ref" => "v1.2.0" }),
     ev(18_000_000_008, "CreateEvent", "alice", "alice/new-tool", 2,
        { "ref_type" => "repository", "description" => "A new tool" }),
     ev(18_000_000_007, "CreateEvent", "alice", "alice/lib", 2, { "ref_type" => "branch", "ref" => "wip" }),
     ev(18_000_000_006, "ForkEvent", "bob", "o/big", 4,
        { "forkee" => { "full_name" => "bob/big", "description" => "fork of big" } }),
     ev(18_000_000_005, "WatchEvent", "bob", "o/starred", 5, { "action" => "started" }),
     ev(18_000_000_004, "WatchEvent", "bob", "o/fresh", 5, { "action" => "started" }),
     ev(18_000_000_003, "IssueCommentEvent", "carol", "o/big", 6,
        { "action" => "created", "issue" => { "number" => 1, "title" => "t" } }),
     ev(18_000_000_002, "PullRequestEvent", "carol", "o/big", 6,
        { "action" => "opened", "number" => 2, "pull_request" => { "number" => 2 } }),
     ev(18_000_000_001, "MemberEvent", "alice", "alice/lib", 7,
        { "action" => "added", "member" => { "login" => "dave" } }),
     ev(18_000_000_000, "PublicEvent", "carol", "carol/opened", 30, {}),]
  end

  def run!
    GN::Collector.new(login: "me", client: GN::Client.new(token: "tok", http: @gh), data: @data, clock: -> { @now }).run
  end

  def feed(hours = 24) = GN::Feed.call(@data, login: "me", hours: hours, now: @now)[:feed]

  def collect!(events = day1, link: nil)
    @gh.set(FEED, events, link: link)
    if @data.db[:gh_stars].empty?
      @data.db[:gh_stars].insert(login: "bob", repo: "o/starred", starred_at: @now - 5 * 3600, first_seen_at: @now)
    end
    run!
  end

  def test_first_read_stores_every_event_and_ranks_releases_and_new_repos_first
    r = collect!
    assert r[:ok], r[:error]
    assert r[:feed_ok], r[:feed_error]
    assert_equal 12, r[:feed_added]
    refute r[:feed_gap], "nothing stored before: not a gap"
    f = feed
    assert_equal 11, f[:total], "the PublicEvent is 30h old"
    assert_equal %w[release repo fork member star], f[:items].map { |i| i[:kind] },
                 "release first, new repo next; the release's tag, the branch and the already-starred repo are not items"
    rel = f[:items][0]
    assert_equal ["alice", "alice/lib", "v1.2.0", "Lib 1.2"], [rel[:actor], rel[:repo], rel[:tag], rel[:name]]
    assert_equal({ repo: "alice/new-tool", description: "A new tool", language: "Go", stars: 12, avatar: AV, topics: ["cli"] },
                 f[:items][1][:card])
    assert_equal "bob/big", f[:items][2][:forkee]
    assert_equal "o/fresh", f[:items][4][:repo]
    assert_equal 1, f[:stars_covered]
    assert_equal [{ repo: "bot/data", pushes: 1, branches: 1, actors: ["bot"] }],
                 f[:pushes].map { |x| x.slice(:repo, :pushes, :branches, :actors) }
    assert_equal({ "comments" => 1, "other" => 2, "pull_requests" => 1 }, f[:activity], "branch create + release's tag → other")
    big = f[:by_repo].find { |x| x[:repo] == "o/big" }
    assert_equal [["ForkEvent", 1, ["bob"]], ["IssueCommentEvent", 1, ["carol"]], ["PullRequestEvent", 1, ["carol"]]],
                 big[:types].map { |t| [t[:type], t[:n], t[:actors]] }
    assert_equal "public", feed(48)[:items].find { |i| i[:repo] == "carol/opened" }[:kind]
    assert f[:status][:ok]
    refute f[:status][:partial], "the first stored event (30h ago) is before the 24h window"
    assert feed(72)[:status][:partial]
  end

  def test_repo_cards_are_fetched_once_and_a_missing_repo_is_not_an_error
    collect!
    urls = @gh.requests.map(&:first)
    assert_equal 1, urls.count("https://api.github.com/repos/alice/new-tool")
    assert_includes urls, "https://api.github.com/repos/bob/big", "the fork's card was asked for (404 here)"
    assert feed[:status][:ok]
    @now += 3600
    collect!(day1 + [ev(18_000_000_020, "WatchEvent", "bob", "x/y", 0.5, { "action" => "started" })])
    assert_equal 1, @gh.requests.map(&:first).count("https://api.github.com/repos/alice/new-tool")
  end

  def test_an_unchanged_feed_costs_one_free_304
    events = day1
    collect!(events)
    @now += 3600
    r = collect!(events)
    assert r[:feed_ok]
    assert_equal 0, r[:feed_calls]
    assert_equal 1, r[:feed_not_modified]
    assert_equal 0, r[:feed_added]
    refute r[:feed_gap]
  end

  def test_new_events_below_already_seen_ids_are_found_on_every_page
    events = day1
    @gh.set("#{FEED}&page=2", events.drop(6))
    collect!(events.first(6), link: "#{FEED}&page=2")
    @now += 3600
    fresh = ev(18_000_000_011, "ReleaseEvent", "bob", "bob/app", 0.2,
               { "action" => "published", "release" => { "tag_name" => "v2" } })
    @gh.set("#{FEED}&page=2", [fresh] + events.drop(6))
    r = run!
    assert r[:feed_ok], r[:feed_error]
    assert_equal [1, 1, 1], [r[:feed_added], r[:feed_not_modified], r[:feed_calls]],
                 "page 1 unchanged (304), the new event is on page 2"
    refute r[:feed_gap]
    assert_equal ["bob/app", "alice/lib"], feed[:items].select { |i| i[:kind] == "release" }.map { |i| i[:repo] }
  end

  def test_new_events_on_page_1_under_a_stored_id_are_found
    events = day1
    collect!(events)
    @now += 3600
    fresh = ev(18_000_000_011, "ReleaseEvent", "bob", "bob/app", 0.2,
               { "action" => "published", "release" => { "tag_name" => "v2" } })
    r = collect!([events[0], fresh] + events.drop(1)) # the higher-id (older) push stays on top
    assert_equal 1, r[:feed_added]
  end

  def test_a_read_with_no_known_event_records_a_gap
    collect!
    @now += 3600
    r = collect!([ev(30_000_000_001, "PushEvent", "bot", "bot/data", 0.1, { "ref" => "refs/heads/b" })])
    assert r[:feed_gap]
    assert_equal @now, feed[:status][:gap_at]
    d = GN::Block.data(GN::Feed.call(@data, login: "me", hours: 24, now: @now), max: 12)
    assert_equal Time.at(@now).iso8601, d.dig("feed", "gap")
  end

  def test_a_failed_feed_is_recorded_and_the_network_still_collects
    @gh.set("/users/me/following?per_page=100&page=1", [])
    r = run! # FEED unset → 404
    assert r[:ok], r[:error]
    refute r[:feed_ok]
    assert_match(/GitHub 404 at \/users\/me\/received_events/, r[:feed_error])
    st = feed[:status]
    refute st[:ok]
    assert_match(/404/, st[:error])
    d = GN::Block.data(GN::Feed.call(@data, login: "me", hours: 24, now: @now), max: 12)
    assert_match(/404/, d.dig("feed", "error"))
  end

  def test_never_collected_says_so
    st = feed[:status]
    refute st[:ok]
    assert_match(/not been collected yet/, st[:error])
  end

  def block_md(max: 12) = GN::Block.markdown(GN::Feed.call(@data, login: "me", hours: 24, now: @now), max: max)
  def unverified(md) = Busyyaks::ReportBlocks.github_unverified(md, @data.db, login: "me")

  def test_block_renders_the_feed_like_github_and_verifies
    collect!
    md = block_md
    html = Busyyaks::Markdown.report(md, store)
    refute_includes html, "tl-error", html[/tl-error.*?<\/div>/m]
    assert_includes html, ">released</span> <a class=\"ghn-rl\" href=\"https://github.com/alice/lib/releases/tag/v1.2.0\""
    assert_includes html, "Lib 1.2"
    assert_includes html, "created a repository"
    assert_includes html, "A new tool"
    assert_includes html, ">forked</span> <a class=\"ghn-rl\" href=\"https://github.com/bob/big\""
    assert_includes html, "<b>1</b> time to"
    assert_includes html, "<b>1</b> comment</span>"
    assert_includes html, "<b>5</b> feed items"
    assert_equal [], unverified(md)
  end

  def test_provenance_rejects_invented_or_edited_feed_items
    collect!
    md = block_md
    assert_equal [], unverified(md)
    probs = unverified(md.sub("tag: v1.2.0", "tag: v9.9.9"))
    assert_equal ["tl:github (block 1): feed release alice/lib (event \"18000000010\") — tag not as stored"], probs
    probs = unverified(md.sub("'18000000008'", "'18000000999'"))
    assert_equal ["tl:github (block 1): feed repo alice/new-tool (event \"18000000999\") — no stored event"], probs
    probs = unverified(md.sub(/pushes: 1\b/, "pushes: 40"))
    assert_equal ["tl:github (block 1): feed pushes to bot/data — 40 > 1 stored"], probs
    probs = unverified(md.sub(/comments: 1\b/, "comments: 7"))
    assert_equal ["tl:github (block 1): feed activity comments — 7 > 1 stored"], probs
    probs = unverified(md.sub("repo: bot/data", "repo: evil/repo"))
    assert_equal ["tl:github (block 1): feed pushes to evil/repo — no stored push in the window"], probs
  end

  def test_block_caps_items_and_pushes_and_counts_the_rest
    events = (1..14).map do |i|
      ev(18_000_001_000 + i, "ReleaseEvent", "alice", "alice/r#{i}", 1,
         { "action" => "published", "release" => { "tag_name" => "v#{i}" } })
    end +
             (1..7).map { |i| ev(18_000_002_000 + i, "PushEvent", "bot", "bot/p#{i}", 1, { "ref" => "refs/heads/main" }) }
    collect!(events)
    d = GN::Block.data(GN::Feed.call(@data, login: "me", hours: 24, now: @now), max: 12)["feed"]
    assert_equal 10, d["items"].size
    assert_equal 5, d["pushes"].size
    assert_equal({ "items" => 4, "pushes" => 2 }, d["more"])
    all = GN::Block.data(GN::Feed.call(@data, login: "me", hours: 24, now: @now), max: nil)["feed"]
    assert_equal [14, 7], [all["items"].size, all["pushes"].size]
  end
end
