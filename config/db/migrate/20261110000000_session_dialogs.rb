# frozen_string_literal: true

# A dialog on an owner session's screen (Claude Code permission prompt / question) posted as a Human input question
# by the notifier: one row per (session, dialog hash) — the dedupe key — with the card it went to and the operator's
# answer (the key the launcher pressed). cards.dialog_id = the open dialog question on that card.
# card_activity.by_operator / undelivered: the operator's comments that reached nobody (no owner session), relayed in one
# ping when the card gains an owner. Existing rows: NULL = an agent's / unknown — nothing is relayed retroactively.
ROM::SQL.migration do
  up do
    create_table :session_dialogs do
      primary_key :id
      column :session, String, null: false
      column :socket, String, null: false
      column :hash, String, null: false
      column :card_id, Integer, null: false
      column :dialog, String, text: true, null: false # SessionDialog.parse JSON
      column :posted_at, Integer, null: false
      column :answered_at, Integer
      column :answered_by, String
      column :answer, String
      index %i[session hash]
    end
    alter_table(:cards) { add_column :dialog_id, Integer }
    alter_table :card_activity do
      add_column :by_operator, TrueClass
      add_column :undelivered, TrueClass
    end
  end

  down do
    alter_table(:card_activity) { drop_column :undelivered; drop_column :by_operator }
    alter_table(:cards) { drop_column :dialog_id }
    drop_table :session_dialogs
  end
end
