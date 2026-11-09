# frozen_string_literal: true

require "test_helper"
require "busyyaks/github_network"
require "busyyaks/markdown"
require_relative "../support/fake_github"

class GithubNetworkTest < Minitest::Test
  include DBReset
  GN = Busyyaks::GithubNetwork
  NOW = Time.utc(2026, 11, 2, 12).to_i

  def setup
    super
    @gh = FakeGithub.new
    @now = NOW
    @data = GN::Data.default
    user("me")
    following("me", %w[alice bob])
    %w[alice bob].each { |u| user(u, name: u.capitalize) }
    following("alice", %w[carol dave])
    following("bob", %w[carol])
    stars("alice", [["o/r1", 2], ["o/old", 24 * 40]])
    stars("bob", [["o/r1", 5]])
    @gh.set("/users/me/received_events?per_page=100", []) # the dashboard feed (github_feed_test.rb)
  end

  def user(login, name: nil)
    @gh.set("/users/#{login}", { "login" => login, "id" => login.sum, "name" => name, "bio" => "#{login} bio",
                                 "avatar_url" => "https://avatars.githubusercontent.com/u/#{login.sum}?v=4",
                                 "html_url" => "https://github.com/#{login}", "followers" => 1200, "public_repos" => 3, })
  end

  def following(login, logins, page: 1)
    @gh.set("/users/#{login}/following?per_page=100&page=#{page}",
            logins.map do |l|
              { "login" => l, "id" => l.sum, "avatar_url" => "https://avatars.githubusercontent.com/u/#{l.sum}?v=4",
                "html_url" => "https://github.com/#{l}", }
            end)
  end

  # [[full_name, hours ago]] newest first
  def stars(login, list, link: nil, path: "/users/#{login}/starred?per_page=100")
    @gh.set(path, list.map do |name, h|
      { "starred_at" => Time.at(@now - (h * 3600)).utc.iso8601,
        "repo" => { "id" => name.sum, "full_name" => name, "html_url" => "https://github.com/#{name}",
                    "description" => "#{name} desc", "language" => "Ruby", "stargazers_count" => 1500,
                    "topics" => %w[cli ruby], "pushed_at" => Time.at(@now).utc.iso8601,
                    "owner" => { "avatar_url" => "https://avatars.githubusercontent.com/u/9?v=4" }, }, }
    end, link: link)
  end

  def run!
    GN::Collector.new(login: "me", client: GN::Client.new(token: "tok", http: @gh), data: @data, clock: -> { @now }).run
  end

  def feed(hours = 24) = GN::Feed.call(@data, login: "me", hours: hours, now: @now)

  def test_first_run_is_a_baseline_for_follows_but_stars_count_by_starred_at
    r = run!
    assert r[:ok], r[:error]
    assert r[:baseline]
    assert_equal 2, r[:followees]
    assert_equal 2, r[:stars_added], "the 40-day-old star is outside LOOKBACK_DAYS"
    assert_equal 0, r[:follows_added], "every follow seen on the first read is the baseline"
    f = feed
    assert_equal [["o/r1", %w[bob alice]]], f[:repos].map { |x| [x[:repo], x[:starred_by]] }
    assert_equal [], f[:people]
    assert f[:status][:ok]
    assert_nil f[:status][:error]
    assert_operator r[:rate_remaining], :<, 5000
  end

  def test_unchanged_network_costs_only_free_304s
    run!
    before = @gh.counted
    r = run!
    assert r[:ok], r[:error]
    refute r[:baseline]
    assert_equal 0, r[:calls], "every page unchanged → only 304s: #{@gh.requests.drop(before).inspect}"
    assert_operator r[:not_modified], :>=, 7
    assert @gh.requests.drop(before).all? { |_, etag, _| etag }, "every request is conditional"
  end

  def test_new_follows_and_stars_after_the_baseline
    run!
    @now += 3600
    following("alice", %w[carol dave erin])
    following("bob", %w[carol erin])
    user("erin", name: "Erin E")
    stars("alice", [["o/r3", 0.5], ["o/r1", 3], ["o/old", 24 * 40]])
    before = @gh.counted
    r = run!
    assert r[:ok], r[:error]
    assert_equal 1, r[:stars_added]
    assert_equal 2, r[:follows_added]
    f = feed
    assert_equal %w[o/r1 o/r3], f[:repos].map { |x| x[:repo] }, "starred by 2 followees ranks above 1"
    assert_equal [["erin", %w[alice bob], "Erin E"]], f[:people].map { |p| [p[:login], p[:followed_by], p[:name]] }
    star_urls = @gh.requests.drop(before).map(&:first).grep(/starred/)
    assert_equal ["https://api.github.com/users/alice/starred?per_page=100",
                  "https://api.github.com/users/bob/starred?per_page=100",], star_urls,
                 "page 1 held an already-stored star: no page 2"
  end

  def test_star_pages_are_read_until_a_stored_star
    stars("alice", [["o/a1", 1]], link: "/users/alice/starred?per_page=100&page=2")
    stars("alice", [["o/a2", 2]], path: "/users/alice/starred?per_page=100&page=2")
    run!
    assert_equal %w[o/a1 o/a2 o/r1], feed[:repos].map { |x| x[:repo] }.sort
  end

  def test_star_pages_stop_at_the_lookback
    stars("alice", [["o/a1", 1], ["o/ancient", 24 * 31]], link: "/users/alice/starred?per_page=100&page=2")
    run!
    refute(@gh.requests.any? { |u, _, _| u.include?("page=2") && u.include?("starred") })
  end

  def test_stars_use_the_star_media_type
    run!
    accepts = @gh.requests.select { |u, _, _| u.include?("/starred") }.map(&:last).uniq
    assert_equal ["application/vnd.github.star+json"], accepts
  end

  def test_a_new_followee_is_baselined_not_reported
    run!
    @now += 3600
    following("me", %w[alice bob frank])
    user("frank")
    following("frank", %w[zed])
    stars("frank", [])
    r = run!
    assert r[:ok], r[:error]
    assert_equal 0, r[:follows_added]
    assert_equal [], feed[:people]
    assert_equal 3, feed[:followees].size
  end

  def test_unfollow_then_follow_again_is_new
    run!
    @now += 3600
    following("bob", [])
    run!
    @now += 3600
    following("bob", %w[carol])
    run!
    assert_equal [["carol", ["bob"]]], feed[:people].map { |p| [p[:login], p[:followed_by]] }
  end

  def test_a_full_following_page_is_followed_by_the_next
    many = (1..100).map { |i| "u#{i}" }
    following("alice", many)
    run!
    assert(@gh.requests.any? { |u, _, _| u.end_with?("/users/alice/following?per_page=100&page=2") })
    @now += 3600
    following("alice", ["newbie"], page: 2)
    user("newbie")
    r = run!
    assert r[:ok], r[:error]
    assert_equal ["newbie"], feed[:people].map { |p| p[:login] }
  end

  def test_rate_limit_is_recorded_and_shown_with_the_last_good_run
    run!
    ok_at = @now
    @now += 3600
    @gh.fail_with = [403, "API rate limit exceeded for user ID 1."]
    r = run!
    refute r[:ok]
    assert_match(/rate limited \(0\/5000 left/, r[:error])
    assert_equal 0, r[:rate_remaining]
    st = feed[:status]
    refute st[:ok]
    assert_match(/rate limited/, st[:error])
    assert_equal ok_at, st[:last_ok_at], "the stored data is labelled with the last good run, not now"
  end

  def test_rejected_token_is_an_error
    @gh.fail_with = [401, "Bad credentials"]
    r = run!
    refute r[:ok]
    assert_equal "GitHub rejected GITHUB_TOKEN (401): Bad credentials", r[:error]
    assert r[:baseline], "nothing was stored: the next run is still the baseline"
  end

  def test_empty_token_and_bad_login_fail_loudly
    assert_raises(GN::Error) { GN::Client.new(token: " ", http: @gh) }
    assert_raises(GN::Error) { GN::Collector.new(login: "bad login", client: GN::Client.new(token: "t", http: @gh), data: @data) }
  end

  def test_never_collected_says_so
    st = feed[:status]
    refute st[:ok]
    assert_match(/no GitHub collection has run yet/, st[:error])
  end

  def test_feed_window_bounds
    assert_raises(ArgumentError) { feed(0) }
    assert_raises(ArgumentError) { feed(721) }
  end

  def test_block_markdown_renders_and_verifies
    run!
    @now += 3600
    following("alice", %w[carol dave erin])
    user("erin", name: "Erin E")
    run!
    md = GN::Block.markdown(feed)
    store.upsert_project(slug: "x", path: "/p/x", remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil, scanned_at: 1)
    html = Busyyaks::Markdown.report(md, store)
    refute_includes html, "tl-error", html[/tl-error.*?<\/div>/m]
    assert_includes html, %(href="https://github.com/o/r1")
    assert_includes html, %(src="https://avatars.githubusercontent.com/u/9?v=4&amp;s=40")
    assert_includes html, ">bob</a> and <a"
    assert_includes html, "Erin E"
    assert_equal [], Busyyaks::ReportBlocks.github_unverified(md, @data.db)
    forged = md.sub("o/r1", "evil/invented")
    assert_equal ["tl:github (block 1): evil/invented — no stored star by @bob",
                  "tl:github (block 1): evil/invented — no stored star by @alice",],
                 Busyyaks::ReportBlocks.github_unverified(forged, @data.db)
  end

  def test_block_caps_and_counts_the_rest
    run!
    f = feed
    f[:repos] = f[:repos] * 3
    d = GN::Block.data(f, max: 1)
    assert_equal 1, d["repos"].size
    assert_equal({ "repos" => 2 }, d["more"])
  end
end
