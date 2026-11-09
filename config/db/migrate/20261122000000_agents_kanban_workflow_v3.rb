# frozen_string_literal: true

require "json"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/host_config"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/board_repo"

# agents_kanban Schema v8 + workflow v3 (card #233). The column types become the fixed set parked · queued · working ·
# review · gate · done · cancelled, and "Human input" stops being a column: a question for the operator is the card's
# needs_operator FLAG (asked_at), an external blocker its blocked_external flag (the new cards columns) — a flagged card
# keeps its place. BoardRepo#migrate_v3! walks EVERY stored board, the template included:
#   - mechanical (every board): the asks_operator column is removed — each card in it goes back to the column its last
#     move came from, the flag and the question kept — and its transitions are dropped; handoff / approved columns are
#     retyped gate (the Approve edge stays and is the approval step); a stale asked_at on a card that was not waiting is
#     cleared. A Human input card whose origin the activity log does not name stops the migration naming it: move it by
#     hand first (nothing is guessed).
#   - the private-mirror boards (detected by their v2 columns approved_mirror · local_merged · deployed · make_public ·
#     public_review — by shape, never by slug): the whole shape becomes the engine's v3 mirror board
#     (fixtures/boards/mirror_v3.board.json: 14 status-named states, the two agent review loops, Cancel / Rework /
#     Reopen / Deploy failed) and every card is moved by the old key → new key map below; a card in a column the map
#     does not know stops the migration naming it.
# Prints one line per board: the retyped columns, the cards returned from Human input, the stale flags cleared, the cards
# moved (reshaped boards).
#
# down: refused. Which gate was the handoff column and which the approved one, and which column a returned card waited
# in, are not recorded in a way that restores workflow v2 exactly — restore the pre-deploy backup instead (the DB copy
# taken before deploying this migration: `pg_dump` on PostgreSQL, the data/busyyaks.sqlite3 copy on SQLite).
#
# (the two tables are local to `up`: the migrator loads this file more than once — a top-level constant would be
# redefined with a warning on every load)
ROM::SQL.migration do
  up do
    mirror_v2_keys = %w[approved_mirror local_merged deployed make_public public_review]
    mirror_cards = {
      "backlog" => "backlog", "todo" => "todo", "doing" => "doing",
      "pre_review" => "mirror_agent_review", "human_check" => "mirror_human_review",
      "approved_mirror" => "mirror_merged", "local_merged" => "mirror_merged", "deployed" => "deploy_check",
      "make_public" => "public_agent_review", "public_review" => "public_human_review",
      "ready" => "awaiting_merge", "merged" => "done",
    }
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 8)
    root = File.expand_path("../../..", __dir__)
    host = AgentsKanban::HostConfig.load(ENV.fetch("KANBAN_CONFIG"))
    v3 = JSON.parse(File.read(File.join(root, "vendor/agents_kanban/fixtures/boards/mirror_v3.board.json")))
    repo = AgentsKanban::BoardRepo.new(self, tables: AgentsKanban::Schema.tables(""), host: host, known: ->(_) { true })
    keys_of = self[:board_columns].all.group_by { |c| c[:project_slug] }.transform_values { |cs| cs.map { |c| c[:key] } }
    mirrors = keys_of.select { |_, keys| (mirror_v2_keys - keys).empty? }.keys.sort
    reshape = mirrors.to_h { |slug| [slug, { "board" => v3, "cards" => mirror_cards }] }
    report = repo.migrate_v3!(cards_t: self[:cards], activity_t: self[:card_activity], by: "migration 20261122000000",
                              reshape: reshape)
    puts "agents_kanban workflow v3: #{report.size} boards (#{mirrors.size} mirror boards reshaped: #{mirrors.join(', ')})"
    report.each do |slug, r|
      cols = r["columns"].map { |k, v| "#{k}: #{v}" }.join(", ")
      moved = r["moved"].map { |k, v| "#{k} ×#{v}" }.join(", ")
      puts "  #{slug.empty? ? '(template)' : slug}: columns [#{cols}] · Human input returned #{r['flagged']} · " \
           "stale flags cleared #{r['flag_cleared']}#{moved.empty? ? '' : " · moved #{moved}"}"
    end
  end

  down do
    raise Sequel::Error, "irreversible: workflow v3 (20261122000000) cannot restore workflow v2 exactly — which gate was " \
                         "the handoff column, which the approved one, and which column each Human input card waited in " \
                         "are not recorded. Restore the pre-deploy backup instead (the DB copy taken before deploying this " \
                         "migration: pg_dump on PostgreSQL, the data/busyyaks.sqlite3 copy on SQLite)."
  end
end
