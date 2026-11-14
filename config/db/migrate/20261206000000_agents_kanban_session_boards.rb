# frozen_string_literal: true

require "yaml"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# agents_kanban Schema v11: boards.archived_at — a SESSION board (an agent session's own board, attached to
# no project; config/kanban.yml session_boards) hidden after session_boards.idle_hours with no activity, its cards
# archived, nothing deleted.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 11)
  end

  # Refused while session boards exist: below v11 a `session:*` board row would read as a project's board. Their
  # cards and rows are data the operator decides about (export, delete) — the rollback never drops them by itself.
  down do
    path = ENV.fetch("KANBAN_CONFIG")
    sb = YAML.safe_load_file(path).fetch("session_boards")
    if sb
      prefix = sb.fetch("slug_prefix")
      held = self[:boards].where(Sequel.function(:substr, :project_slug, 1, prefix.length) => prefix).select_map(:project_slug)
      unless held.empty?
        raise "rollback refused: #{held.size} session board(s) exist (#{held.first(10).join(', ')}) — below schema v11 " \
              "they would read as project boards; remove them (their cards, then the boards / board_columns / " \
              "board_transitions rows) first"
      end
    end
    alter_table(:boards) { drop_column :archived_at }
  end
end
