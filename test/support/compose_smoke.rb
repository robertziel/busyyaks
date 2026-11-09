# frozen_string_literal: true

# CI's compose PostgreSQL smoke (scripts/ci/test.sh ruby-pg): run in the compose `test` service as HOST_UID with the
# `postgres` profile's socket volume. Boots the app the way the services do, then writes a project, a card and a
# comment through the kanban engine. Prints one line; exits non-zero on anything else than a PostgreSQL connection
# that wrote them.
ENV["HANAMI_ENV"] ||= "test"
require "hanami/prepare"

db = Hanami.app["db.gateway"].connection
abort "smoke: connected to #{db.database_type}, not postgres" unless db.database_type == :postgres

Busyyaks::Store.default.upsert_project(slug: "smoke/r", path: "/nonexistent", remote: nil, branch: "main", own: true,
                                       last_commit_at: 1, commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil,
                                       scanned_at: 1)
store = Busyyaks::Kanban.store
id = store.create(slug: "smoke/r", title: "smoke", by: "ci")
store.comment(id, body: "smoke", author: "ci")
puts "smoke: uid #{Process.uid} · #{db.get(Sequel.function(:current_database))} via #{ENV.fetch('POSTGRES_HOST')} · " \
     "card #{id} · #{db[:card_activity].where(card_id: id, kind: 'comment').count} comment"
