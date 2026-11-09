# frozen_string_literal: true

require "json"

# Trello parity for the kanban (lib/busyyaks/kanban.rb):
# - board_labels: each board's label set (name + colour key from Kanban::LABEL_COLORS). cards.labels keeps the names.
#   Existing card labels are backfilled as "gray" (the explicit no-colour label); the operator recolours them.
# - cards.due_at (epoch, nil = no due date), cards.due_done (0/1), cards.cover (a LABEL_COLORS key or nil).
# - card_activity.edited_at: a comment edited by its author (shown as "edited").
# - checklists / checklist_items: one or more checklists per card; item body is markdown (rendered inline).
ROM::SQL.migration do
  up do
    create_table :board_labels do
      primary_key :id
      column :project_slug, String, null: false
      column :name, String, null: false
      column :color, String, null: false
      column :created_at, Integer, null: false
      index %i[project_slug name], unique: true
    end

    alter_table :cards do
      add_column :due_at, Integer
      add_column :due_done, Integer, null: false, default: 0
      add_column :cover, String
    end

    alter_table :card_activity do
      add_column :edited_at, Integer
    end

    create_table :checklists do
      primary_key :id
      foreign_key :card_id, :cards, null: false, on_delete: :cascade
      column :title, String, null: false
      column :position, Integer, null: false
      column :created_at, Integer, null: false
      index :card_id
    end

    create_table :checklist_items do
      primary_key :id
      foreign_key :checklist_id, :checklists, null: false, on_delete: :cascade
      column :body, String, text: true, null: false
      column :done, Integer, null: false, default: 0
      column :position, Integer, null: false
      column :done_by, String
      column :done_at, Integer
      column :created_at, Integer, null: false
      index :checklist_id
    end

    now = Time.now.to_i
    seen = {}
    self[:cards].select(:project_slug, :labels).each do |r|
      JSON.parse(r[:labels]).each do |name|
        next if seen[[r[:project_slug], name]]

        seen[[r[:project_slug], name]] = true
        self[:board_labels].insert(project_slug: r[:project_slug], name: name, color: "gray", created_at: now)
      end
    end
  end

  down do
    drop_table :checklist_items
    drop_table :checklists
    drop_table :board_labels
    alter_table(:card_activity) { drop_column :edited_at }
    alter_table(:cards) do
      drop_column :cover
      drop_column :due_done
      drop_column :due_at
    end
  end
end
