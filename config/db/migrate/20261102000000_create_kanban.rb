# frozen_string_literal: true

# Per-project kanban (lib/busyyaks/kanban.rb). column is a key of Kanban::COLUMNS; position orders cards
# within a column (0-based, renumbered on every move). labels is a JSON array of strings.
# archived_at set → off the board, still listed under "archived".
# card_activity: comments (kind "comment") and the card's history (create/move/update/archive), with who did it.
ROM::SQL.migration do
  change do
    create_table :cards do
      primary_key :id
      column :project_slug, String, null: false
      column :column, String, null: false
      column :position, Integer, null: false
      column :title, String, null: false
      column :notes, String, text: true, null: false, default: ""
      column :labels, String, text: true, null: false, default: "[]"
      column :assignee, String
      column :priority, String
      column :created_by, String, null: false
      column :created_at, Integer, null: false
      column :updated_at, Integer, null: false
      column :archived_at, Integer
      index %i[project_slug column position]
    end

    create_table :card_activity do
      primary_key :id
      foreign_key :card_id, :cards, null: false, on_delete: :cascade
      column :kind, String, null: false
      column :body, String, text: true, null: false
      column :author, String, null: false
      column :created_at, Integer, null: false
      index :card_id
    end
  end
end
