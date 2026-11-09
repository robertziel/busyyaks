# frozen_string_literal: true

# The scanner reads every repo through libgit2 in a killable child (lib/busyyaks/git_read.rb) and now also stores
# what the card links used to ask git for on every card view:
#   branches     JSON list of the repo's branch names (local + remote-tracking, the remote's name dropped)
#   default_ref  the checked-out branch ("HEAD" when detached or unborn)
#   git_error    why the last scan could not read the repo (or its daily series); nil = read. The row keeps its
#                last good values beside it.
ROM::SQL.migration do
  up do
    alter_table(:projects) do
      add_column :branches, String, text: true
      add_column :default_ref, String
      add_column :git_error, String, text: true
    end
  end

  down do
    alter_table(:projects) do
      %i[branches default_ref git_error].each { |c| drop_column c }
    end
  end
end
