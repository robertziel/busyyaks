# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/host_config"
require_relative "../../../lib/busyyaks/agent_settings" # the file is read without its agent part
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/board_repo"

# The private side is named "local", not "mirror" (card #249):
#   - projects: the scanner's enrolment columns mirror_mode / mirror_repo / mirror_error → local_mode / local_repo /
#     local_error (read from guard.mirrorRemote now; public_repo / public_head keep their names).
#   - every stored board — the template too — that holds the workflow v3 private-board columns (the engine's
#     mirror_v3 shape that 20261122000000 gave those boards): the engine's BoardRepo#rename_columns! turns them into
#     local_v3 (fixtures/boards/local_v3.board.json): keys mirror_agent_review · mirror_author · mirror_human_review ·
#     mirror_merged → local_agent_review · local_author · local_human_review · local_merged_pr, labels "Mirror: …" →
#     "Local: …", "Local deploy check" → "Local: Deploy check" (key deploy_check kept), transition "Open mirror PR" →
#     "Open local PR". The cards (archived too), their review_rounds keys and their move / create entries follow. A board
#     that already holds one of the new keys stops the migration, naming it (nothing written).
# The host config's review_loop.columns name the review columns by key: config/kanban.yml lists local_agent_review
# from this release on (the example and the suite's fixture do). A config that still names a key this rename removes
# (or, down, one it brings back) would turn the round limit off without a word: the migration refuses it, naming the key
# — fix config/kanban.yml first.
# Prints one line per board renamed.
#
# down: the inverse maps (the same call), then the columns back.
#
# (the maps are local to the blocks: the migrator loads this file more than once — a top-level constant would be
# redefined with a warning on every load)
ROM::SQL.migration do
  up do
    cols = {
      "mirror_agent_review" => { "key" => "local_agent_review", "label" => "Local: Agent review" },
      "mirror_author" => { "key" => "local_author", "label" => "Local: Author response" },
      "mirror_human_review" => { "key" => "local_human_review", "label" => "Local: Human review" },
      "mirror_merged" => { "key" => "local_merged_pr", "label" => "Local: Merged" },
    }
    # the label of deploy_check changes only on a board that has the renamed columns (a key named deploy_check on
    # another board is that board's own column)
    cols["deploy_check"] = { "label" => "Local: Deploy check" }
    host = Busyyaks::AgentSettings.migration_host(ENV.fetch("KANBAN_CONFIG"))
    repo = AgentsKanban::BoardRepo.new(self, tables: AgentsKanban::Schema.tables(""), host: host, known: ->(_) { true })
    keyed = self[:board_columns].where(key: cols.keys - ["deploy_check"]).select_map(:project_slug).uniq
    stale = keyed.empty? || host.review_loop.nil? ? [] : host.review_loop.columns & cols.keys
    if stale.any?
      raise Sequel::Error, "config/kanban.yml review_loop.columns names #{stale.join(', ')}, which this migration renames " \
                           "(#{stale.map { |k| cols[k]['key'] }.join(', ')}): rename it there first, then migrate"
    end
    report = if keyed.empty? then {}
             else
               repo.rename_columns!(columns: cols, transitions: { "Open mirror PR" => "Open local PR" }, slugs: keyed,
                                    cards_t: self[:cards], activity_t: self[:card_activity],
                                    by: "migration 20261130000000")
             end
    alter_table(:projects) do
      rename_column :mirror_mode, :local_mode
      rename_column :mirror_repo, :local_repo
      rename_column :mirror_error, :local_error
    end
    puts "local naming: #{report.size} boards renamed"
    report.each { |slug, r| puts "  #{slug.empty? ? '(template)' : slug}: #{r.map { |k, v| "#{k} #{v}" }.join(' · ')}" }
  end

  down do
    cols = {
      "local_agent_review" => { "key" => "mirror_agent_review", "label" => "Mirror: Agent review" },
      "local_author" => { "key" => "mirror_author", "label" => "Mirror: Author response" },
      "local_human_review" => { "key" => "mirror_human_review", "label" => "Mirror: Human review" },
      "local_merged_pr" => { "key" => "mirror_merged", "label" => "Mirror merged" },
    }
    cols["deploy_check"] = { "label" => "Local deploy check" }
    host = Busyyaks::AgentSettings.migration_host(ENV.fetch("KANBAN_CONFIG"))
    repo = AgentsKanban::BoardRepo.new(self, tables: AgentsKanban::Schema.tables(""), host: host, known: ->(_) { true })
    keyed = self[:board_columns].where(key: cols.keys - ["deploy_check"]).select_map(:project_slug).uniq
    stale = keyed.empty? || host.review_loop.nil? ? [] : host.review_loop.columns & cols.keys
    if stale.any?
      raise Sequel::Error, "config/kanban.yml review_loop.columns names #{stale.join(', ')}, which this rollback renames " \
                           "back (#{stale.map { |k| cols[k]['key'] }.join(', ')}): restore the pre-#249 config/kanban.yml " \
                           "first, then roll back"
    end
    unless keyed.empty?
      repo.rename_columns!(columns: cols, transitions: { "Open local PR" => "Open mirror PR" }, slugs: keyed,
                           cards_t: self[:cards], activity_t: self[:card_activity], by: "migration 20261130000000 down")
    end
    alter_table(:projects) do
      rename_column :local_mode, :mirror_mode
      rename_column :local_repo, :mirror_repo
      rename_column :local_error, :mirror_error
    end
  end
end
