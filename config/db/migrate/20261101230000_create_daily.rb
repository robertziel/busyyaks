# frozen_string_literal: true

# Commits per repo per day for a year: the contribution graph. Replaced per repo on every scan.
ROM::SQL.migration do
  change do
    create_table :daily do
      column :project_slug, String, null: false
      column :day, String, null: false # YYYY-MM-DD, committer's local date
      column :commits, Integer, null: false
      column :mine, Integer, null: false
      primary_key %i[project_slug day]
      index :day
    end
  end
end
