# frozen_string_literal: true

# Operator approval on a Human Check card: who and when. An approved card may be moved to Merged by its agent.
ROM::SQL.migration do
  change do
    alter_table :cards do
      add_column :approved_at, Integer
      add_column :approved_by, String
    end
  end
end
