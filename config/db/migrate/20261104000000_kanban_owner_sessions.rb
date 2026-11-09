# frozen_string_literal: true

# The tmux session responsible for a card (pinged on new comments, watched by the notifier's watchdog) and the
# queue of pings to deliver.
ROM::SQL.migration do
  up do
    alter_table :cards do
      add_column :owner_session, String
      add_column :owner_socket, String
      add_column :owner_missing_since, Integer
    end
    create_table :card_pings do
      primary_key :id
      column :card_id, Integer, null: false
      column :session, String, null: false
      column :socket, String, null: false
      column :text, String, text: true, null: false
      column :reason, String, null: false          # comment | move
      column :status, String, null: false           # pending | sent | failed
      column :attempts, Integer, null: false, default: 0
      column :error, String, text: true
      column :created_at, Integer, null: false
      column :done_at, Integer
      index %i[status created_at]
    end
  end

  down do
    drop_table :card_pings
    alter_table(:cards) { drop_column :owner_missing_since; drop_column :owner_socket; drop_column :owner_session }
  end
end
