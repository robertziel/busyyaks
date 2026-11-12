# frozen_string_literal: true

# setup_completions: who finished (or skipped) the first-run hello screen, when. The SPA shell opens
# /hello while the table is empty; every later finish adds a row (the newest is shown). down: the table goes — the
# next page load opens /hello again.
ROM::SQL.migration do
  up do
    create_table(:setup_completions) do
      primary_key :id
      String :author, null: false
      Integer :created_at, null: false
    end
  end

  down do
    drop_table(:setup_completions)
  end
end
