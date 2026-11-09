# frozen_string_literal: true

# The agent's Human Check handoff: how to QA it, its PR and CI build, and whether it changes UI (then screenshots
# must be attached). Written by kanban_handoff, shown at the top of the card.
ROM::SQL.migration do
  change do
    alter_table :cards do
      add_column :qa_notes, String, text: true
      add_column :pr_url, String
      add_column :ci_url, String
      add_column :ui_change, TrueClass
      add_column :handoff_at, Integer
      add_column :handoff_by, String
    end
  end
end
