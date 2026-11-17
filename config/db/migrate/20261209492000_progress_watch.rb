# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"

# The progress watch. agents_kanban Schema v13 = the stretch on the card (cards.progress_at, progress_marks,
# progress_pinged_at, progress_commented_at, progress_stale_at, progress_error); projects.branch_tips = the scanner's
# {branch => [tip shas]} (GitReader#branch_tips), so "a new commit on a branch the card names" is read from the scan
# (CiChecks::Port#progress); projects.remote_heads = the branches the remotes' HEAD names (GitReader#remote_heads: each
# remote's default branch — never a card's progress). Nil until the scanner reads the repo again.
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 13)
    alter_table(:projects) do
      add_column :branch_tips, String, text: true
      add_column :remote_heads, String, text: true
    end
  end

  down do
    alter_table(:projects) do
      drop_column :remote_heads
      drop_column :branch_tips
    end
    stretch = %i[progress_at progress_marks progress_pinged_at progress_commented_at progress_stale_at progress_error]
    alter_table(:cards) { stretch.each { |c| drop_column c } }
  end
end
