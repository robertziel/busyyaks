# frozen_string_literal: true

# dictation_settings (card 634): what the card dialog's mic runs — once config/busyyaks.yml `dictation` — as
# revisions; the newest row is the current one (Busyyaks::DictationSettings), edited on Settings → Dictation. Nothing
# is seeded: no revision = the mic is off. A deployment that had the block imports it once
# (bin/dictation-settings import < file). down: the table goes, and with it every revision — put the dictation block
# back into config/busyyaks.yml first.
ROM::SQL.migration do
  up do
    create_table(:dictation_settings) do
      primary_key :id
      String :doc, text: true, null: false # JSON {enabled, model, timeout_seconds, max_seconds}
      String :author, null: false
      Integer :created_at, null: false
    end
  end

  down do
    drop_table(:dictation_settings)
  end
end
