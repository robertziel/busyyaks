# frozen_string_literal: true

# GitHub network (lib/busyyaks/github_network.rb): who GITHUB_LOGIN follows, what they star, whom they follow.
# Snapshots written by the `github` compose service (bin/github); read by the MCP tool github_network and /github.
ROM::SQL.migration do
  change do
    # profiles: followees (refreshed every run, conditional) and accounts they newly follow (fetched once)
    create_table :gh_users do
      column :login, String, null: false, primary_key: true
      column :gh_id, Integer
      column :name, String
      column :bio, String, text: true
      column :avatar_url, String
      column :html_url, String
      column :followers, Integer
      column :public_repos, Integer
      column :profile_at, Integer # when name/bio/followers were fetched; nil = never
      column :following_synced_at, Integer # first full read of this user's following list = their follows baseline
    end

    # follower → followee edges. baseline: present at the follower's first read (never reported as new).
    # gone_at: no longer in the follower's list (unfollowed).
    create_table :gh_follows do
      column :follower, String, null: false
      column :followee, String, null: false
      column :first_seen_at, Integer, null: false
      column :last_seen_at, Integer, null: false
      column :baseline, TrueClass, null: false
      column :gone_at, Integer
      primary_key %i[follower followee]
      index :followee
      index :first_seen_at
    end

    create_table :gh_repos do
      column :full_name, String, null: false, primary_key: true
      column :gh_id, Integer
      column :description, String, text: true
      column :language, String
      column :stargazers_count, Integer
      column :html_url, String, null: false
      column :owner_avatar, String
      column :topics, String, text: true # JSON array
      column :pushed_at, Integer
      column :fetched_at, Integer, null: false # stargazers_count etc. are as of this time
    end

    # starred_at is GitHub's (Accept: application/vnd.github.star+json): authoritative from the first run
    create_table :gh_stars do
      column :login, String, null: false
      column :repo, String, null: false
      column :starred_at, Integer, null: false
      column :first_seen_at, Integer, null: false
      primary_key %i[login repo]
      index :starred_at
    end

    # conditional requests: the last ETag of each URL whose answer has been stored, and what that answer held (a 304
    # page of a following list still has to say which logins are on it)
    create_table :gh_pages do
      column :url, String, null: false, primary_key: true
      column :etag, String, null: false
      column :items, String, text: true # JSON: logins on the page (following lists); nil when the caller needs none
      column :at, Integer, null: false
    end

    create_table :gh_runs do
      primary_key :id
      column :login, String, null: false
      column :started_at, Integer, null: false
      column :finished_at, Integer
      column :ok, TrueClass
      column :error, String, text: true
      column :baseline, TrueClass, null: false, default: false # first run: follows seen now are the baseline
      column :calls, Integer, null: false, default: 0          # requests that counted (200 / errors)
      column :not_modified, Integer, null: false, default: 0   # 304s (free with a token)
      column :rate_limit, Integer
      column :rate_remaining, Integer
      column :rate_reset, Integer
      column :followees, Integer
      column :stars_added, Integer   # star rows stored this run (the baseline stores the last LOOKBACK_DAYS)
      column :follows_added, Integer # follows first seen this run, baselines excluded
    end
  end
end
