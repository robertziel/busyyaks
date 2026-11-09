# frozen_string_literal: true

# The repo's own icon file (lib/busyyaks/icons.rb picks it): path relative to the repo, its mtime (cache key).
ROM::SQL.migration do
  change do
    alter_table :projects do
      add_column :icon_path, String
      add_column :icon_mtime, Integer
    end
  end
end
