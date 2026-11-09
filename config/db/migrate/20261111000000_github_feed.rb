# frozen_string_literal: true

# GitHub dashboard feed (github.com/feed = GET /users/:login/received_events): every event the `github` collector
# reads, once (event id), with a small digest of its payload. Read by github_network (feed part), /github and the
# tl:github block's feed section; check_report verifies every feed item against these rows.
ROM::SQL.migration do
  up do
    create_table :gh_events do
      column :login, String, null: false        # whose feed (GITHUB_LOGIN)
      column :id, String, null: false           # GitHub's event id (not time-ordered across id ranges)
      column :type, String, null: false         # PushEvent, ReleaseEvent, …
      column :action, String                    # payload.action (published, started, added, opened, …)
      column :actor, String, null: false
      column :actor_avatar, String
      column :repo, String, null: false
      column :public, TrueClass
      column :created_at, Integer, null: false  # GitHub's created_at
      column :first_seen_at, Integer, null: false
      column :digest, String, text: true, null: false # JSON: the payload fields the feed shows (tag, ref, forkee, …)
      primary_key %i[login id]
      index %i[login created_at]
    end
    alter_table :gh_runs do
      add_column :feed_ok, TrueClass            # nil = the feed step did not run
      add_column :feed_error, String, text: true
      add_column :feed_added, Integer           # events stored this run
      add_column :feed_calls, Integer           # requests the feed step made that counted (200 / errors)
      add_column :feed_not_modified, Integer
      add_column :feed_gap, TrueClass           # none of the fetched events was stored before: events in between may be lost
    end
  end

  down do
    alter_table :gh_runs do
      %i[feed_gap feed_not_modified feed_calls feed_added feed_error feed_ok].each { |c| drop_column c }
    end
    drop_table :gh_events
  end
end
