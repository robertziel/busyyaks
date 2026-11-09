# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "time"
require "yaml"
require "set"
require_relative "github_feed"

module Busyyaks
  # The operator's GitHub network: who GITHUB_LOGIN follows (followees), what they star, whom they follow.
  #
  # Collector (bin/github, its own compose service, every GITHUB_INTERVAL_SECONDS) snapshots into SQLite (gh_*):
  # - stars: GET /users/:f/starred newest first with starred_at (star+json). Page 1 is conditional (If-None-Match);
  #   pages are read until an already-stored star or one older than LOOKBACK_DAYS. starred_at is GitHub's, so "new in
  #   the window" is right from the first run.
  # - follows: GET /users/:f/following has no timestamps and is oldest-first (a new follow lands on the LAST page), so
  #   every page is read conditionally (a 304 is free and reuses the page's stored logins). "New" = first seen after
  #   that follower's first full read (their baseline), which is never reported.
  # - profiles of followees (conditional, every run) and of accounts they newly follow (once).
  # Every run is recorded in gh_runs: ok or the error (token rejected, rate limited, unreachable) + the rate limit left.
  # A failed run keeps what earlier runs stored; the feed shows the error and the last good run's time beside it.
  module GithubNetwork
    API = "https://api.github.com"
    JSON_ACCEPT = "application/vnd.github+json"
    STAR_ACCEPT = "application/vnd.github.star+json"
    PER_PAGE = 100
    # The longest window /github and github_network offer (30d): a star older than this is never "new", so the baseline
    # and the "read until seen" pagination stop there.
    LOOKBACK_DAYS = 30
    MAX_HOURS = LOOKBACK_DAYS * 24
    LOGIN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/
    REPO = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
    AVATAR = %r{\Ahttps://avatars\.githubusercontent\.com/[A-Za-z0-9_./?=&%-]+\z}

    class Error < StandardError; end
    class RateLimited < Error; end

    # get(url, headers) → [status, {lowercased header => value}, body]; network failures raise Error.
    class Http
      def get(url, headers)
        uri = URI(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |h|
          r = h.get(uri.request_uri, headers)
          [r.code.to_i, r.each_header.to_h, r.body.to_s]
        end
      rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Error, "GitHub unreachable: #{e.class}: #{e.message}"
      end
    end

    Page = Struct.new(:status, :body, :etag, :next_url, keyword_init: true) do
      def not_modified? = status == 304
    end

    class Client
      attr_reader :calls, :not_modified, :rate

      def initialize(token:, http: Http.new)
        raise Error, "GITHUB_TOKEN is empty" if token.to_s.strip.empty?

        @token = token
        @http = http
        @calls = 0
        @not_modified = 0
        @rate = {}
      end

      # missing_ok: a 404 answers Page(status: 404) instead of raising (a repo deleted or not visible to the token)
      def get(url, accept: JSON_ACCEPT, etag: nil, missing_ok: false)
        url = "#{API}#{url}" if url.start_with?("/")
        headers = { "Authorization" => "Bearer #{@token}", "Accept" => accept, "X-GitHub-Api-Version" => "2022-11-28",
                    "User-Agent" => "busyyaks-github-network", }
        headers["If-None-Match"] = etag if etag
        status, h, body = @http.get(url, headers)
        track(h)
        if status == 304
          @not_modified += 1
          return Page.new(status: 304)
        end
        @calls += 1
        return Page.new(status: 404) if status == 404 && missing_ok

        fail!(status, h, body, url) unless status == 200
        Page.new(status: 200, body: JSON.parse(body), etag: h["etag"], next_url: next_link(h["link"]))
      rescue JSON::ParserError => e
        raise Error, "GitHub answered #{url} with non-JSON: #{e.message[0, 80]}"
      end

      private

      def track(h)
        return unless h["x-ratelimit-remaining"]

        @rate = { limit: h["x-ratelimit-limit"].to_i,
                  remaining: h["x-ratelimit-remaining"].to_i,
                  reset: h["x-ratelimit-reset"].to_i, }
      end

      def fail!(status, h, body, url)
        msg = begin
          JSON.parse(body)["message"].to_s
        rescue JSON::ParserError
          body.to_s[0, 120]
        end
        path = url.delete_prefix(API)
        if status == 429 || (status == 403 && (h["x-ratelimit-remaining"] == "0" || msg.match?(/rate limit/i)))
          reset = h["x-ratelimit-reset"] ? Time.at(h["x-ratelimit-reset"].to_i).strftime("%H:%M") : "unknown"
          raise RateLimited, "GitHub rate limited (#{h['x-ratelimit-remaining'] || '?'}/" \
                             "#{h['x-ratelimit-limit'] || '?'} left, resets #{reset}) at #{path}: #{msg}"
        end
        raise Error, "GitHub rejected GITHUB_TOKEN (401): #{msg}" if status == 401

        raise Error, "GitHub #{status} at #{path}: #{msg}"
      end

      def next_link(link)
        link.to_s.split(",").map(&:strip).each do |part|
          m = part.match(/\A<([^>]+)>;\s*rel="next"\z/)
          return m[1] if m
        end
        nil
      end
    end

    # SQL over the gh_* tables (the db is hanami-db's Sequel connection, like Store's).
    class Data
      def self.default = new(Hanami.app["db.gateway"].connection)

      attr_reader :db

      def initialize(db)
        @db = db
      end

      # --- runs
      def run_started(login, at, baseline:) = @db[:gh_runs].insert(login: login, started_at: at, baseline: baseline)
      def run_finished(id, attrs) = @db[:gh_runs].where(id: id).update(attrs)
      def last_run(login) = @db[:gh_runs].where(login: login).exclude(finished_at: nil).order(Sequel.desc(:id)).first
      def last_ok_run(login) = @db[:gh_runs].where(login: login, ok: true).order(Sequel.desc(:id)).first
      def first_ok_run(login) = @db[:gh_runs].where(login: login, ok: true).order(:id).first
      def running(login) = @db[:gh_runs].where(login: login, finished_at: nil).order(Sequel.desc(:id)).first

      # --- conditional pages
      def page(url) = @db[:gh_pages].where(url: url).first

      def save_page(url, etag, at, items: nil)
        return unless etag

        row = { etag: etag, items: items && JSON.generate(items), at: at }
        @db[:gh_pages].where(url: url).update(row).zero? && @db[:gh_pages].insert(row.merge(url: url))
      end

      # --- users
      def user(login) = @db[:gh_users].where(login: login).first

      def upsert_user(login, attrs)
        @db[:gh_users].where(login: login).update(attrs).zero? && @db[:gh_users].insert(attrs.merge(login: login))
      end

      def users(logins) = logins.empty? ? {} : @db[:gh_users].where(login: logins.uniq).all.to_h { |u| [u[:login], u] }

      # --- follows: one follower's full current list → the logins that are new follows (not baseline)
      def sync_follows(follower, logins, at, baseline:)
        fresh = []
        @db.transaction do
          have = @db[:gh_follows].where(follower: follower).all.to_h { |r| [r[:followee], r] }
          logins.uniq.each do |l|
            row = have[l]
            if row.nil?
              @db[:gh_follows].insert(follower: follower, followee: l, first_seen_at: at, last_seen_at: at, baseline: baseline)
              fresh << l unless baseline
            elsif row[:gone_at]
              # unfollowed earlier, followed again: a new follow
              @db[:gh_follows].where(follower: follower, followee: l)
                              .update(first_seen_at: at, last_seen_at: at, gone_at: nil, baseline: false)
              fresh << l
            else
              @db[:gh_follows].where(follower: follower, followee: l).update(last_seen_at: at)
            end
          end
          gone = have.keys - logins
          @db[:gh_follows].where(follower: follower, followee: gone, gone_at: nil).update(gone_at: at) unless gone.empty?
        end
        fresh
      end

      def followees(login) = @db[:gh_follows].where(follower: login, gone_at: nil).select_map(:followee).sort_by(&:downcase)

      # --- stars
      def star?(login, repo) = !@db[:gh_stars].where(login: login, repo: repo).empty?

      def upsert_repo(full_name, attrs)
        @db[:gh_repos].where(full_name: full_name).update(attrs).zero? &&
          @db[:gh_repos].insert(attrs.merge(full_name: full_name))
      end

      # true when the star is new to the store
      def add_star(login, repo, starred_at, at)
        return false if star?(login, repo)

        @db[:gh_stars].insert(login: login, repo: repo, starred_at: starred_at, first_seen_at: at)
        true
      end
    end

    class Collector
      include FeedSync

      def initialize(login:, client:, data:, clock: -> { Time.now.to_i })
        raise Error, "GITHUB_LOGIN #{login.inspect} is not a GitHub login" unless login.to_s.match?(LOGIN)

        @login = login
        @client = client
        @data = data
        @clock = clock
      end

      # → the run row. Never raises for a GitHub failure: the error is the run's result.
      def run
        now = @clock.call
        baseline = @data.first_ok_run(@login).nil?
        id = @data.run_started(@login, now, baseline: baseline)
        stars = 0
        follows = 0
        followees = []
        @feed = feed_step(now) # the dashboard feed (github_feed.rb): its own status, so a failed feed never hides the network
        begin
          sync_following(@login, now) # the operator's own follows: none are reported, only the list matters
          followees = @data.followees(@login)
          followees.each { |f| profile(f, now, conditional: true) }
          followees.each { |f| stars += sync_stars(f, now) }
          followees.each do |f|
            fresh = sync_following(f, now)
            follows += fresh.size
            fresh.each { |l| profile(l, now, conditional: false) unless @data.user(l)&.fetch(:profile_at) }
          end
          finish(id, ok: true, error: nil, followees: followees.size, stars_added: stars, follows_added: follows)
        rescue Error => e
          finish(id, ok: false, error: e.message, followees: followees.size, stars_added: stars, follows_added: follows)
        end
        @data.db[:gh_runs].where(id: id).first
      end

      private

      def finish(id, **attrs)
        r = @client.rate
        @data.run_finished(id, attrs.merge(@feed || {}).merge(finished_at: @clock.call, calls: @client.calls,
                                                              not_modified: @client.not_modified, rate_limit: r[:limit],
                                                              rate_remaining: r[:remaining], rate_reset: r[:reset]))
      end

      # every page of /users/:who/following, each conditional (a 304 reuses the page's stored logins). Pages are numbered,
      # not followed by Link: a full page is always followed by the next one, so a new follow that starts a new page is
      # found even when the full page before it answers 304 (an empty page's ETag is stable: 304 next time, free).
      # → the follows that are new (not this follower's baseline)
      def sync_following(who, now)
        logins = []
        n = 1
        loop do
          url = "#{API}/users/#{who}/following?per_page=#{PER_PAGE}&page=#{n}"
          cached = @data.page(url)
          page = @client.get(url, etag: cached && cached[:etag])
          items = if page.not_modified?
                    JSON.parse(cached[:items])
                  else
                    page.body.map do |u|
                      unless @data.user(u["login"])
                        @data.upsert_user(u["login"], { gh_id: u["id"], avatar_url: u["avatar_url"], html_url: u["html_url"] })
                      end
                      u["login"]
                    end
                  end
          logins.concat(items)
          @data.save_page(url, page.etag, now, items: items) unless page.not_modified?
          break if items.size < PER_PAGE

          n += 1
        end
        u = @data.user(who)
        baseline = u.nil? || u[:following_synced_at].nil?
        fresh = @data.sync_follows(who, logins, now, baseline: baseline)
        @data.upsert_user(who, { following_synced_at: now }) if baseline
        fresh
      end

      def sync_stars(who, now)
        cutoff = now - (LOOKBACK_DAYS * 86_400)
        first = "#{API}/users/#{who}/starred?per_page=#{PER_PAGE}"
        url = first
        added = 0
        etag_first = nil
        while url
          page = @client.get(url, accept: STAR_ACCEPT, etag: url == first ? @data.page(first)&.dig(:etag) : nil)
          return added if page.not_modified?

          etag_first = page.etag if url == first
          stop = page.next_url.nil?
          @data.db.transaction do
            page.body.each do |s|
              at = Time.iso8601(s["starred_at"]).to_i
              r = s["repo"]
              if @data.star?(who, r["full_name"])
                stop = true
                store_repo(r, now)
                next
              end
              if at < cutoff
                stop = true
                next
              end
              store_repo(r, now)
              added += 1 if @data.add_star(who, r["full_name"], at, now)
            end
          end
          url = stop ? nil : page.next_url
        end
        @data.save_page(first, etag_first, now)
        added
      end

      def store_repo(r, now)
        @data.upsert_repo(r["full_name"], {
                            gh_id: r["id"], description: r["description"], language: r["language"],
                            stargazers_count: r["stargazers_count"], html_url: r["html_url"],
                            owner_avatar: r.dig("owner", "avatar_url"), topics: JSON.generate(r["topics"] || []),
                            pushed_at: r["pushed_at"] && Time.iso8601(r["pushed_at"]).to_i, fetched_at: now,
                          })
      end

      def profile(login, now, conditional:)
        url = "#{API}/users/#{login}"
        page = @client.get(url, etag: conditional ? @data.page(url)&.dig(:etag) : nil)
        return if page.not_modified?

        b = page.body
        @data.upsert_user(login, { gh_id: b["id"], name: b["name"], bio: b["bio"], avatar_url: b["avatar_url"],
                                   html_url: b["html_url"], followers: b["followers"], public_repos: b["public_repos"],
                                   profile_at: now, })
        @data.save_page(url, page.etag, now) if conditional
      end
    end

    # What the window holds, read from the snapshots: repos the followees starred in it (grouped, most stargazers
    # among the followees first), accounts they started following in it, and the collector's state.
    module Feed
      module_function

      def call(data, login:, hours:, now: Time.now.to_i)
        raise ArgumentError, "hours must be 1..#{MAX_HOURS}, got #{hours}" unless (1..MAX_HOURS).cover?(hours)

        from = now - (hours * 3600)
        followees = data.followees(login)
        network = data.users(followees)
        { window: { hours: hours, from: from, to: now }, login: login, status: status(data, login, from),
          followees: followees.map { |f| person(f, network[f]) },
          repos: repos(data, followees, from, now), people: people(data, login, followees, from),
          feed: FeedEvents.call(data, login: login, from: from, to: now), }
      end

      def status(data, login, from)
        last = data.last_run(login)
        ok = data.last_ok_run(login)
        first = data.first_ok_run(login)
        running = data.running(login)
        error = if last.nil?
                  running ? "first collection is running" : "no GitHub collection has run yet (compose service github)"
                elsif !last[:ok] then last[:error]
                end
        { ok: !last.nil? && last[:ok] ? true : false, error: error,
          last_run_at: last && last[:finished_at], last_ok_at: ok && ok[:finished_at],
          running_since: running && running[:started_at],
          calls: last && last[:calls], not_modified: last && last[:not_modified],
          rate_remaining: last && last[:rate_remaining], rate_limit: last && last[:rate_limit],
          rate_reset: last && last[:rate_reset],
          # follows are only known from the first good run on: a window that starts earlier cannot list older ones
          follows_since: first && first[:finished_at], follows_partial: first.nil? || first[:finished_at] > from, }
      end

      def repos(data, followees, from, now)
        return [] if followees.empty?

        rows = data.db[:gh_stars].where(login: followees).where { starred_at >= from }.where { starred_at <= now }.all
        meta = data.db[:gh_repos].where(full_name: rows.map { |r| r[:repo] }.uniq).all.to_h { |r| [r[:full_name], r] }
        rows.group_by { |r| r[:repo] }.map do |name, stars|
          m = meta.fetch(name)
          by = stars.sort_by { |s| s[:starred_at] }
          { repo: name, url: m[:html_url], description: m[:description], language: m[:language], stars: m[:stargazers_count],
            topics: JSON.parse(m[:topics] || "[]"), avatar: m[:owner_avatar], pushed_at: m[:pushed_at],
            fetched_at: m[:fetched_at], starred_by: by.map { |s| s[:login] }, starred_at: by.map { |s| s[:starred_at] },
            last_starred_at: by.last[:starred_at], }
        end.sort_by { |r| [-r[:starred_by].size, -r[:last_starred_at], r[:repo].downcase] }
      end

      def people(data, login, followees, from)
        return [] if followees.empty?

        rows = data.db[:gh_follows].where(follower: followees, baseline: false, gone_at: nil)
                   .where { first_seen_at >= from }.all
        mine = data.followees(login).to_set
        users = data.users(rows.map { |r| r[:followee] })
        rows.group_by { |r| r[:followee] }.map do |l, fs|
          by = fs.sort_by { |f| f[:first_seen_at] }
          person(l, users[l]).merge(followed_by: by.map { |f| f[:follower] }, first_seen_at: by.first[:first_seen_at],
                                    you_follow: mine.include?(l), is_you: l.casecmp?(login))
        end.sort_by { |p| [-p[:followed_by].size, -p[:first_seen_at], p[:login].downcase] }
      end

      def person(login, u)
        { login: login, name: u && u[:name], bio: u && u[:bio], avatar: u && u[:avatar_url],
          followers: u && u[:followers], public_repos: u && u[:public_repos], }
      end
    end

    # The tl:github block for a feed, as markdown to paste verbatim into a report (the daily report does exactly that:
    # the model never writes a repo or a login itself). At most `max` repos and people; the rest are counted.
    module Block
      module_function

      def markdown(feed, max: 12) = "```tl:github\n#{YAML.dump(data(feed, max: max)).delete_prefix("---\n")}```\n"

      # the block's body as a hash (string keys); max nil = everything
      def data(feed, max:)
        st = feed[:status]
        repos = max ? feed[:repos].first(max) : feed[:repos]
        people = max ? feed[:people].first(max) : feed[:people]
        fd = feed[:feed] && feed_data(feed[:feed], max: max)
        logins = (repos.flat_map { |r| r[:starred_by] } + people.flat_map { |p| p[:followed_by] } +
                  (fd ? Array(fd["items"]).map { |i| i["actor"] } + Array(fd["pushes"]).flat_map { |x| x["by"] } : [])).uniq
        avatars = feed[:followees].to_h { |f| [f[:login], f[:avatar]] }
        if feed[:feed]
          feed[:feed][:items].each { |i| avatars[i[:actor]] ||= i[:avatar] }
          feed[:feed][:pushes].each { |x| x[:avatars].each { |l, a| avatars[l] ||= a } }
        end
        h = { "window" => window_label(feed[:window][:hours]), "to" => Time.at(feed[:window][:to]).iso8601 }
        h["collected"] = Time.at(st[:last_ok_at]).iso8601 if st[:last_ok_at]
        h["error"] = st[:error] if st[:error]
        h["follows_since"] = Time.at(st[:follows_since]).iso8601 if st[:follows_partial] && st[:follows_since]
        h["network"] = logins.to_h { |l| [l, avatars[l]] } unless logins.empty?
        h["repos"] = repos.map { |r| repo(r) } unless repos.empty?
        h["people"] = people.map { |p| person(p) } unless people.empty?
        h["feed"] = fd if fd
        more = { "repos" => feed[:repos].size - repos.size, "people" => feed[:people].size - people.size }
               .reject { |_, v| v.zero? }
        h["more"] = more unless more.empty?
        h
      end

      # the feed part: items (releases and new repos first, max FEED_ITEMS_MAX), pushes per repo (max FEED_PUSHES_MAX),
      # every other event counted per category; the rest counted under more
      def feed_data(f, max:)
        st = f[:status]
        items = max ? f[:items].first(FEED_ITEMS_MAX) : f[:items]
        pushes = max ? f[:pushes].first(FEED_PUSHES_MAX) : f[:pushes]
        h = {}
        h["error"] = st[:error] if st[:error]
        h["since"] = Time.at(st[:since]).iso8601 if st[:partial] && st[:since]
        h["gap"] = Time.at(st[:gap_at]).iso8601 if st[:gap_at]
        h["items"] = items.map { |i| feed_item(i) } unless items.empty?
        unless pushes.empty?
          h["pushes"] = pushes.map do |x|
            { "repo" => x[:repo], "pushes" => x[:pushes], "branches" => x[:branches], "by" => x[:actors],
              "at" => Time.at(x[:last_at]).iso8601, }
          end
        end
        h["activity"] = f[:activity].transform_keys(&:to_s) unless f[:activity].empty?
        more = { "items" => f[:items].size - items.size, "pushes" => f[:pushes].size - pushes.size }.reject { |_, v| v.zero? }
        h["more"] = more unless more.empty?
        h
      end

      def feed_item(i)
        c = i[:card] || {}
        { "id" => i[:id], "kind" => i[:kind], "actor" => i[:actor], "repo" => i[:repo], "at" => Time.at(i[:at]).iso8601,
          "tag" => i[:tag], "name" => i[:name], "prerelease" => i[:prerelease], "ref" => i[:ref], "member" => i[:member],
          "forkee" => i[:forkee], "description" => c[:description], "language" => c[:language], "stars" => c[:stars],
          "topics" => c[:topics].nil? || c[:topics].empty? ? nil : c[:topics].first(5), "avatar" => c[:avatar], }.compact
      end

      def window_label(hours) = (hours % 24).zero? ? "#{hours / 24}d" : "#{hours}h"

      def repo(r)
        {
          "repo" => r[:repo], "description" => r[:description], "language" => r[:language], "stars" => r[:stars],
          "topics" => r[:topics].empty? ? nil : r[:topics].first(5), "avatar" => r[:avatar],
          "starred_by" => r[:starred_by], "starred_at" => Time.at(r[:last_starred_at]).iso8601,
        }.compact
      end

      def person(p)
        { "login" => p[:login], "name" => p[:name], "bio" => p[:bio], "avatar" => p[:avatar], "followers" => p[:followers],
          "followed_by" => p[:followed_by], "you_follow" => p[:you_follow] || nil, }.compact
      end
    end
  end
end
