# frozen_string_literal: true

require "json"
require "time"

module Busyyaks
  # The operator's GitHub dashboard feed (what github.com/feed shows): GET /users/:login/received_events with
  # GITHUB_TOKEN — events by the people they follow and on the repos they watch, private ones the token can see
  # included. GitHub keeps at most 300 events / 90 days there (3 pages of 100).
  #
  # Order on that endpoint is by event id, and GitHub's event ids are not time-ordered across id ranges (2026: a block of
  # 2597… ids from Nov 1 sorts above Nov 2's 1893… ids), so "stop at the first seen id" would stop at once and miss
  # everything new. Every run therefore reads page 1 conditionally (a 304 = nothing changed, free) and, when it changed,
  # all pages (≤ 3 calls), storing the ids not seen before. When none of the fetched ids was stored before, events
  # between the two reads may have been pushed past the 300 cap: the run records feed_gap and the feed says so.
  module GithubNetwork
    FEED_PER_PAGE = 100

    # The feed's items, by importance: what a daily report shows first.
    FEED_RANK = { "release" => 0, "repo" => 1, "public" => 1, "fork" => 2, "member" => 3, "tag" => 4, "star" => 5 }.freeze
    # Events that are never items, counted per category only (they are most of the feed: 65% on a real day, on 3 repos)
    FEED_ACTIVITY = {
      "IssueCommentEvent" => "comments", "PullRequestReviewCommentEvent" => "comments", "CommitCommentEvent" => "comments",
      "IssuesEvent" => "issues", "PullRequestEvent" => "pull_requests", "PullRequestReviewEvent" => "reviews",
      "DiscussionEvent" => "discussions", "DiscussionCommentEvent" => "comments",
    }.freeze
    FEED_ITEMS_MAX = 10 # in a report; /github shows every item
    FEED_PUSHES_MAX = 5

    # The payload fields the feed shows, per event type (the rest of a payload is not stored).
    def self.feed_digest(type, p)
      case type
      when "CreateEvent", "DeleteEvent"
        { "ref_type" => p["ref_type"], "ref" => p["ref"], "description" => p["description"] }
      when "ForkEvent"
        f = p["forkee"] || {}
        { "forkee" => f["full_name"], "description" => f["description"], "language" => f["language"] }
      when "ReleaseEvent"
        r = p["release"] || {}
        { "tag" => r["tag_name"], "name" => r["name"], "prerelease" => r["prerelease"], "draft" => r["draft"],
          "url" => r["html_url"], }
      when "MemberEvent" then { "member" => p.dig("member", "login") }
      when "PushEvent" then { "ref" => p["ref"], "head" => p["head"], "size" => p["size"] }
      when "IssuesEvent", "IssueCommentEvent" then { "number" => p.dig("issue", "number"), "title" => p.dig("issue", "title") }
      when "PullRequestEvent", "PullRequestReviewEvent", "PullRequestReviewCommentEvent"
        { "number" => p.dig("pull_request", "number") || p["number"], "title" => p.dig("pull_request", "title") }
      else {}
      end.compact
    end

    # the item kind of a stored event, nil when it is not an item (counted as activity / pushes instead)
    def self.feed_kind(type, action, d)
      case type
      when "ReleaseEvent" then action == "published" && !d["draft"] ? "release" : nil
      when "CreateEvent" then { "repository" => "repo", "tag" => "tag" }[d["ref_type"]]
      when "PublicEvent" then "public"
      when "ForkEvent" then d["forkee"] ? "fork" : nil
      when "MemberEvent" then action == "added" && d["member"] ? "member" : nil
      when "WatchEvent" then "star"
      end
    end

    # Collector part (included into Collector): one read of the feed → the gh_runs feed_* attributes. Never raises.
    module FeedSync
      private

      def feed_step(now)
        calls = @client.calls
        nm = @client.not_modified
        added, gap = sync_feed(now)
        { feed_ok: true, feed_error: nil, feed_added: added, feed_gap: gap,
          feed_calls: @client.calls - calls, feed_not_modified: @client.not_modified - nm, }
      rescue Error => e
        { feed_ok: false, feed_error: e.message, feed_added: 0, feed_gap: false,
          feed_calls: @client.calls - calls, feed_not_modified: @client.not_modified - nm, }
      end

      # → [events stored, gap?]. Every page is conditional (a 304 page holds only stored events; its stored `next` link
      # says where the feed goes on), so a new event that sorts onto page 2 or 3 is found while page 1 is unchanged.
      def sync_feed(now)
        url = "#{API}/users/#{@login}/received_events?per_page=#{FEED_PER_PAGE}"
        events = []
        saves = []
        unchanged = 0
        while url
          cached = @data.page(url)
          page = @client.get(url, etag: cached && cached[:etag])
          if page.not_modified?
            unchanged += 1
            url = JSON.parse(cached[:items] || "{}")["next"]
          else
            events.concat(page.body)
            saves << [url, page.etag, page.next_url]
            url = page.next_url
          end
        end
        ids = events.map { |e| e["id"].to_s }
        mine = @data.db[:gh_events].where(login: @login)
        had = !mine.empty?
        known = ids.empty? ? Set.new : mine.where(id: ids).select_map(:id).to_set
        fresh = events.reject { |e| known.include?(e["id"].to_s) }.uniq { |e| e["id"].to_s }
        @data.db.transaction do
          fresh.each do |e|
            type = e["type"].to_s
            p = e["payload"] || {}
            @data.db[:gh_events].insert(
              login: @login, id: e["id"].to_s, type: type, action: p["action"], actor: e.dig("actor", "login").to_s,
              actor_avatar: e.dig("actor", "avatar_url"), repo: e.dig("repo", "name").to_s, public: e["public"],
              created_at: Time.iso8601(e["created_at"]).to_i, first_seen_at: now,
              digest: JSON.generate(GithubNetwork.feed_digest(type, p))
            )
          end
        end
        fresh.each { |e| feed_repo(e, now) }
        saves.each { |u, etag, nxt| @data.save_page(u, etag, now, items: { "next" => nxt }) }
        [fresh.size, had && unchanged.zero? && !events.empty? && known.empty?]
      end

      # a new repo / a repo made public / a fork: its card (description, language, stars, owner avatar) once
      def feed_repo(e, now)
        p = e["payload"] || {}
        name = case e["type"]
               when "CreateEvent" then p["ref_type"] == "repository" ? e.dig("repo", "name") : nil
               when "PublicEvent" then e.dig("repo", "name")
               when "ForkEvent" then p.dig("forkee", "full_name")
               end
        return if name.nil? || !name.match?(REPO) || @data.db[:gh_repos].where(full_name: name).count.positive?

        page = @client.get("#{API}/repos/#{name}", missing_ok: true)
        store_repo(page.body, now) if page.status == 200 # 404: deleted since, or not visible — the event alone is shown
      end
    end

    # The feed in [from, to], read from gh_events: highlighted items (releases and new repos first), pushes summarised
    # per repo, every event grouped by repo then type (with actors), the rest counted per category, and its status.
    module FeedEvents
      module_function

      def call(data, login:, from:, to:)
        rows = data.db[:gh_events].where(login: login).where { created_at >= from }.where { created_at <= to }
                   .order(Sequel.desc(:created_at), Sequel.desc(:id)).all
        rows.each { |r| r[:d] = JSON.parse(r[:digest]) }
        release_tags = rows.select { |r| r[:type] == "ReleaseEvent" }.to_set { |r| [r[:repo], r[:d]["tag"]] }
        stars = starred(data, rows)
        items = []
        activity = Hash.new(0)
        covered = 0
        rows.each do |r|
          kind = GithubNetwork.feed_kind(r[:type], r[:action], r[:d])
          kind = nil if kind == "tag" && release_tags.include?([r[:repo], r[:d]["ref"]]) # the release says it
          if kind == "star" && stars.include?([r[:actor], r[:repo]])
            covered += 1 # already under Starred (the stars collector)
          elsif kind
            items << r.merge(kind: kind)
          elsif r[:type] != "PushEvent"
            activity[FEED_ACTIVITY.fetch(r[:type], "other")] += 1
          end
        end
        repos = data.db[:gh_repos].where(full_name: items.map { |i| card_repo(i) }.compact.uniq).all
                    .to_h { |x| [x[:full_name], x] }
        { status: status(data, login, from), total: rows.size,
          counts: rows.group_by { |r| r[:type] }.transform_values(&:size).sort_by { |t, n| [-n, t] }.to_h,
          items: items.sort_by { |i| [FEED_RANK.fetch(i[:kind]), -i[:created_at], i[:id]] }.map { |i| item(i, repos) },
          pushes: pushes(rows), by_repo: by_repo(rows), activity: activity.sort_by { |k, n| [-n, k] }.to_h,
          stars_covered: covered, }
      end

      def starred(data, rows)
        w = rows.select { |r| r[:type] == "WatchEvent" }
        return Set.new if w.empty?

        data.db[:gh_stars].where(login: w.map { |r| r[:actor] }.uniq, repo: w.map { |r| r[:repo] }.uniq)
            .select_map(%i[login repo]).to_set
      end

      def card_repo(i) = { "repo" => i[:repo], "public" => i[:repo], "fork" => i[:d]["forkee"] }[i[:kind]]

      def item(i, repos)
        d = i[:d]
        h = { id: i[:id], kind: i[:kind], type: i[:type], actor: i[:actor], avatar: i[:actor_avatar], repo: i[:repo],
              at: i[:created_at], }
        case i[:kind]
        when "release" then h.merge!(tag: d["tag"], name: d["name"], prerelease: d["prerelease"] ? true : nil, url: d["url"])
        when "tag" then h[:ref] = d["ref"]
        when "member" then h[:member] = d["member"]
        when "fork" then h[:forkee] = d["forkee"]
        end
        name = card_repo(i)
        if name
          m = repos[name]
          h[:card] = { repo: name, description: m ? m[:description] : d["description"],
                       language: m ? m[:language] : d["language"], stars: m && m[:stargazers_count],
                       avatar: m && m[:owner_avatar], topics: m ? JSON.parse(m[:topics] || "[]") : [], }
        end
        h.compact
      end

      def pushes(rows)
        rows.select { |r| r[:type] == "PushEvent" }.group_by { |r| r[:repo] }.map do |repo, ps|
          { repo: repo, pushes: ps.size, branches: ps.map { |p| p[:d]["ref"] }.compact.uniq.size,
            actors: ps.group_by { |p| p[:actor] }.sort_by { |a, x| [-x.size, a.downcase] }.map(&:first),
            avatars: ps.to_h { |p| [p[:actor], p[:actor_avatar]] }, last_at: ps.map { |p| p[:created_at] }.max, }
        end.sort_by { |p| [-p[:pushes], -p[:last_at], p[:repo].downcase] }
      end

      def by_repo(rows)
        rows.group_by { |r| r[:repo] }.map do |repo, es|
          types = es.group_by { |r| r[:type] }.map do |t, x|
            { type: t, n: x.size, actors: x.group_by { |r| r[:actor] }.sort_by { |a, y| [-y.size, a.downcase] }.map(&:first) }
          end
          { repo: repo, total: es.size, last_at: es.map { |r| r[:created_at] }.max,
            types: types.sort_by { |t| [-t[:n], t[:type]] }, }
        end.sort_by { |r| [-r[:total], -r[:last_at], r[:repo].downcase] }
      end

      def status(data, login, from)
        runs = data.db[:gh_runs].where(login: login).exclude(feed_ok: nil)
        last = runs.exclude(finished_at: nil).order(Sequel.desc(:id)).first
        ok = runs.where(feed_ok: true).order(Sequel.desc(:id)).first
        gap = runs.where(feed_gap: true).where { started_at >= from }.order(Sequel.desc(:id)).first
        since = data.db[:gh_events].where(login: login).min(:created_at)
        error = if last.nil? then "the feed has not been collected yet (compose service github)"
                elsif !last[:feed_ok] then last[:feed_error]
                end
        { ok: !last.nil? && last[:feed_ok] ? true : false, error: error, last_run_at: last && last[:finished_at],
          last_ok_at: ok && ok[:finished_at], calls: last && last[:feed_calls], not_modified: last && last[:feed_not_modified],
          added: last && last[:feed_added],
          # GitHub keeps 300 events: a window older than the first stored event cannot be complete
          since: since, partial: since.nil? || since > from, gap_at: gap && gap[:started_at], }
      end
    end
  end
end
