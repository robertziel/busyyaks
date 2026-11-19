# frozen_string_literal: true

# workflow_files (card #429): the writer service's sync state of each project's `<repo>/.busyyaks/workflow.yml` — the
# file's path, the sha of the bytes last applied to the board (or written from it), when, and the refusal the board
# shows (error + since when) while the file cannot be applied; checked_at = the writer's last look (a stale one says
# the writer is down). down: the table goes; the boards tables keep the last applied shapes.
ROM::SQL.migration do
  up do
    create_table(:workflow_files) do
      String :project_slug, null: false, primary_key: true
      String :path, text: true, null: false
      String :applied_sha
      Integer :applied_at
      String :error, text: true
      Integer :error_at
      Integer :checked_at, null: false
    end
  end

  down do
    drop_table(:workflow_files)
  end
end
