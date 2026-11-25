# frozen_string_literal: true

# projects.detached_sha = the commit a detached HEAD points at (null when HEAD names a branch). The scanner
# stored a detached checkout's branch as "", shown as a blank; now branch is null and this column says the state.
# The up clears every stored "" branch to null (a blank branch is never a name); detached_sha is only known from a
# scan, so a repo detached before this migration shows "—" (not read) until the next scan fills it — one scan
# interval, accepted.
ROM::SQL.migration do
  up do
    alter_table(:projects) { add_column :detached_sha, String }
    self[:projects].where(branch: "").update(branch: nil)
  end

  down do
    alter_table(:projects) { drop_column :detached_sha }
  end
end
