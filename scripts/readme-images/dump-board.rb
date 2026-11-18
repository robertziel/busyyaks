# frozen_string_literal: true

# The README screenshot environment's dump (scripts/readme-images/dump): busyyaks' own board as the live dashboard
# shows it, read from the live database — READ ONLY, nothing is written. Run inside the live web container:
#   docker compose exec -T -e DUMP_SLUG=<slug> -e DUMP_CARD=<id> -e DUMP_CANDIDATES=<n> -e DUMP_COVER_COLUMNS=<n> web \
#     bundle exec ruby -I lib - < scripts/readme-images/dump-board.rb > raw.json
# Prints one JSON document: the board's shape (columns, transitions), its labels, the cards the board shows (not
# archived; a card older than its column's hide_after_hours left out) plus DUMP_CARD, their activity, checklists and
# # items, the PR states GitHub last answered for their PRs, and their picture attachments with the bytes — the
# CANDIDATES dump.js picks from — only where a README shot shows a picture:
# DUMP_CARD's every one, and the newest DUMP_CANDIDATES of each card in the board's first DUMP_COVER_COLUMNS
# columns (the board shot's, its card covers); every other card keeps no picture. Nothing is
# renamed or chosen here: dump.js renames and gates every word and picture before anything is kept.
ENV["LOG_LEVEL"] = "warn"
require "json"
require "set"
require "base64"
require "sequel"
require "busyyaks/database"
require "busyyaks/clock"

slug = ENV.fetch("DUMP_SLUG")
card_id = Integer(ENV.fetch("DUMP_CARD"), 10)
candidates = Integer(ENV.fetch("DUMP_CANDIDATES"), 10)
cover_columns = Integer(ENV.fetch("DUMP_COVER_COLUMNS"), 10)
root = ENV.fetch("ATTACHMENTS_DIR")
setup = Busyyaks::Database.from_env
# read only, enforced by the database: a SQLite file opened readonly; a PostgreSQL session whose every transaction is
# READ ONLY (set on each pooled connection as it opens)
db = if setup.adapter == "sqlite"
       Sequel.connect(setup.url, **setup.options, readonly: true)
     else
       Sequel.connect(adapter: "postgres", **setup.options,
                      after_connect: ->(c) { c.exec("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY") })
     end
now = Busyyaks::Clock.epoch

columns = db[:board_columns].where(project_slug: slug).order(:position).all
raise "dump-board: #{slug} has no board" if columns.empty?

hide = columns.to_h { [_1[:key], _1[:hide_after_hours]] }
visible = db[:cards].where(project_slug: slug, archived_at: nil).all.select do |c|
  h = hide.fetch(c[:column]) { raise "dump-board: card #{c[:id]} is in #{c[:column]}, not a column of #{slug}" }
  h.nil? || c[:updated_at] >= now - (h * 3600)
end
card = db[:cards].where(id: card_id, project_slug: slug).first
raise "dump-board: card #{card_id} is not on #{slug}" unless card

cards = (visible + [card]).uniq { _1[:id] }
ids = cards.map { _1[:id] }
checklists = db[:checklists].where(card_id: ids).all
images = db[:card_attachments].where(card_id: ids, deleted_at: nil).where(Sequel.like(:content_type, "image/%"))
                              .order(Sequel.desc(:created_at), Sequel.desc(:id)).all
shown = columns.first(cover_columns).map { _1[:key] }
covered = cards.select { shown.include?(_1[:column]) }.to_set { _1[:id] }
kept = images.group_by { _1[:card_id] }.flat_map do |cid, list|
  next list if cid == card_id

  covered.include?(cid) ? list.first(candidates) : []
end
attachments = kept.map do |a|
  bytes = File.binread(File.join(root, a[:stored_path]))
  raise "dump-board: attachment #{a[:id]} size differs from its row" unless bytes.bytesize == a[:size]

  a.except(:stored_path).merge(bytes: Base64.strict_encode64(bytes))
end

# the state GitHub last answered for each PR the cards hold (metadata prs): the Links rail's merged / open tags
pr_urls = cards.flat_map { |c| c[:metadata] ? (JSON.parse(c[:metadata])["prs"] || []).map { _1["url"] } : [] }.uniq
pr_states = db[:gh_pr_states].where(url: pr_urls).all

puts JSON.generate(
  slug: slug, card: card_id, exported_at: now,
  columns: columns, transitions: db[:board_transitions].where(project_slug: slug).order(:position).all,
  labels: db[:board_labels].where(project_slug: slug).all,
  cards: cards, activity: db[:card_activity].where(card_id: ids).order(:id).all,
  checklists: checklists, items: db[:checklist_items].where(checklist_id: checklists.map { _1[:id] }).all,
  attachments: attachments, pr_states: pr_states,
  # every enrolled project's local + public repo (the scanner's read of its guard.* config): busyyaks' and its engine's
  # repos are renamed to the demo's names by these, never by a list in code
  enrolments: db[:projects].exclude(local_mode: nil).select(:slug, :local_repo, :public_repo).all,
)
