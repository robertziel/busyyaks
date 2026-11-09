# frozen_string_literal: true

# The "Human input" column (key human_input, between To do and In progress): an agent parks a card there with
# kanban_ask — the question (markdown) and optional answer choices live on the card until the next ask.
# Existing rows need no change: `column` is a plain string, no card is in human_input before this, and every
# existing column key keeps its meaning (only Kanban::COLUMNS' order grew by one key).
ROM::SQL.migration do
  change do
    alter_table :cards do
      add_column :question, String, text: true
      add_column :question_options, String, text: true # JSON array of strings, NULL = free answer
      add_column :asked_at, Integer
      add_column :asked_by, String
    end
  end
end
