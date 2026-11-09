# frozen_string_literal: true

ROM::SQL.migration do
  change do
    create_table :projects do
      primary_key :id
      column :slug, String, null: false, unique: true
      column :path, String, null: false
      column :remote, String
      column :branch, String
      column :own, TrueClass, null: false
      column :last_commit_at, Integer
      column :commits_window, Integer, null: false
      column :mine_window, Integer, null: false
      column :dirty, Integer, null: false
      column :unpushed, Integer
      column :scanned_at, Integer, null: false
      column :present, TrueClass, null: false, default: true
    end

    create_table :commits do
      primary_key :id
      column :project_slug, String, null: false
      column :sha, String, null: false
      column :author, String, null: false
      column :email, String, null: false
      column :committed_at, Integer, null: false
      column :subject, String, null: false
      column :mine, TrueClass, null: false
      index %i[project_slug sha], unique: true
      index :committed_at
    end

    create_table :reports do
      primary_key :id
      column :date, String, null: false
      column :title, String, null: false
      column :body_md, String, text: true, null: false
      column :author, String, null: false
      column :created_at, Integer, null: false
      index :date
    end

    create_table :notes do
      primary_key :id
      column :project_slug, String
      column :body, String, text: true, null: false
      column :author, String, null: false
      column :created_at, Integer, null: false
      index :project_slug
    end

    create_table :scans do
      primary_key :id
      column :started_at, Integer, null: false
      column :finished_at, Integer
      column :repos, Integer
      column :error, String, text: true
    end
  end
end
