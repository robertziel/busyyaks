# frozen_string_literal: true

# The README screenshot environment: loads a dump into the demo stack's fresh database, as the busyyaks board. Run by
# scripts/readme-images/build inside the demo web container, the dump mounted read-only at /dump:
#   docker compose … exec -T -e DUMP_DIR=/dump web bundle exec ruby -I lib - load|touch < scripts/readme-images/load-dump.rb
# The database is the env's (DATABASE_ADAPTER + its keys, lib/busyyaks/database.rb).
require "json"
require "sequel"
require "securerandom"
require "fileutils"
require "busyyaks/clock" # from the image's lib/ (-I lib): stdin has no file to require relative to
require "busyyaks/database"

module Busyyaks
  # The README screenshot environment's loader: a dump (scripts/readme-images/dump — busyyaks' own board, renamed and
  # gated) into the demo stack's fresh database, as the busyyaks board; tested by test/unit/readme_load_dump_test.rb
  # (which requires this file: run as a program only, below).
  #
  # load:  the board's shape, labels, cards (their ids kept: the README opens the dump's card by its id), activity,
  #        checklists, attachments (the files written under attachments_dir), the PR states and busyyaks' merged PRs —
  #        every time (each column named *_at holding an epoch) moved forward by (now − the dump's time), so the board
  #        reads as it did when it was dumped. Refuses a database that already holds a busyyaks card (load once per
  #        stack).
  # touch: the PR states read now (the board shows a state GitHub answered within the last few poll intervals; the demo
  #        runs no poller) — build runs it right before each capture.
  module ReadmeLoadDump
    Refused = Class.new(StandardError)

    # → the line to print; raises Refused naming why
    def self.run(mode, db:, env:)
      case mode
      when "touch" then touch(db)
      # DEMO_GITHUB_LOGIN: the demo's GitHub account (build passes it; seed-github.rb connects it)
      when "load" then load(db, env.fetch("DUMP_DIR"), env.fetch("ATTACHMENTS_DIR"), env.fetch("DEMO_GITHUB_LOGIN"))
      else raise Refused, "load-dump: #{mode.inspect} is not load or touch"
      end
    end

    def self.touch(db)
      now = Busyyaks::Clock.epoch
      n = db[:gh_pr_states].where(Sequel.like(:url, "https://github.com/dev-example/%"))
                           .update(requested_at: now, checked_at: now)
      "load-dump: #{n} PR states read now"
    end

    def self.load(db, dir, root, login)
      dump = JSON.parse(File.read(File.join(dir, "board.json")), symbolize_names: true)
      merged = JSON.parse(File.read(File.join(dir, "merged.json")), symbolize_names: true)
      slug = dump.fetch(:slug)
      now = Busyyaks::Clock.epoch
      shift = now - dump.fetch(:exported_at)
      later = ->(t) { t && (t + shift) }
      # a time = a column named *_at holding an epoch (an Integer): moved, whatever table; nothing else is
      moved = ->(row) { row.to_h { |k, v| [k, k.end_with?("_at") && v.is_a?(Integer) ? later.call(v) : v] } }
      # only the columns this database has (the dump and the demo are one schema; a column the dump lacks stays default)
      fit = ->(table, row) { row.slice(*db[table].columns) }

      if db[:cards].where(project_slug: slug).any?
        raise Refused, "load-dump: the demo already holds #{slug} cards: load once per stack"
      end

      db.transaction do
        %i[board_transitions board_columns board_labels boards].each { db[_1].where(project_slug: slug).delete }
        db[:boards].insert(project_slug: slug, updated_by: "operator", updated_at: now, created_at: now)
        dump[:columns].each { db[:board_columns].insert(fit.call(:board_columns, _1.except(:id))) }
        dump[:transitions].each { db[:board_transitions].insert(fit.call(:board_transitions, _1.except(:id))) }
        dump[:labels].each { db[:board_labels].insert(fit.call(:board_labels, moved.call(_1.except(:id)))) }
        dump[:cards].each { db[:cards].insert(fit.call(:cards, moved.call(_1))) }
        dump[:activity].each { db[:card_activity].insert(fit.call(:card_activity, moved.call(_1))) }
        dump[:checklists].each { db[:checklists].insert(fit.call(:checklists, moved.call(_1))) }
        dump[:items].each { db[:checklist_items].insert(fit.call(:checklist_items, moved.call(_1))) }
        dump[:attachments].each do |a|
          bytes = File.binread(File.join(dir, "attachments", a.fetch(:file)))
          raise Refused, "load-dump: picture #{a[:id]} is not the size its row says" unless bytes.bytesize == a.fetch(:size)

          rel = "#{a[:card_id]}/#{SecureRandom.hex(16)}"
          FileUtils.mkdir_p(File.join(root, a[:card_id].to_s))
          File.binwrite(File.join(root, rel), bytes)
          db[:card_attachments].insert(fit.call(:card_attachments, moved.call(a.except(:file)).merge(stored_path: rel)))
        end
        dump[:pr_states].each { db[:gh_pr_states].insert(fit.call(:gh_pr_states, moved.call(_1.except(:id)))) }
        merged.each do |p|
          at = later.call(p.fetch(:merged_at))
          db[:gh_merged_prs].insert(login: login, repo: p[:repo], number: p[:number], title: p[:title], url: p[:url],
                                    merged_at: at, first_seen_at: at)
        end
      end
      "load-dump: #{dump[:cards].size} cards, #{dump[:activity].size} activity, #{dump[:attachments].size} pictures, " \
        "#{merged.size} merged PRs on #{slug} (moved forward #{shift} s)"
    end
  end
end

# run as a program (from stdin, as build runs it, or by its path); its test requires it and calls run
if ["-", __FILE__].include?($PROGRAM_NAME)
  mode = ARGV.fetch(0) { abort "load-dump: load or touch" }
  setup = Busyyaks::Database.from_env
  db = if setup.adapter == "sqlite"
         Sequel.connect(setup.url, **setup.options)
       else
         Sequel.connect(adapter: "postgres", **setup.options)
       end
  begin
    puts Busyyaks::ReadmeLoadDump.run(mode, db: db, env: ENV)
  rescue Busyyaks::ReadmeLoadDump::Refused => e
    abort e.message
  end
end
