# frozen_string_literal: true

# Agents sidebar "done" (herdr's semantics): a session whose turn ended after the operator last looked at it.
# One row per session key (socket/name): when the operator last saw it — opened its row, or its tmux session was
# attached. A key's first sighting counts as seen (a new session is not "done" until a turn ends after that).
ROM::SQL.migration do
  up do
    create_table :agent_seen do
      column :key, String, null: false, primary_key: true # "<socket>/<session name>"
      column :seen_at, Float, null: false
    end
  end

  down do
    drop_table :agent_seen
  end
end
