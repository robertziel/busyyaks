# frozen_string_literal: true

# Files attached to a card (and optionally to one of its comments). The bytes live under ATTACHMENTS_DIR/<card_id>/
# with a random name (stored_path, relative to that root); filename is the sanitized display name, never a path.
# deleted_at = soft delete: the row stays (the activity says who deleted it), the file is no longer served.
ROM::SQL.migration do
  up do
    create_table :card_attachments do
      primary_key :id
      column :card_id, Integer, null: false
      column :activity_id, Integer                 # the comment (card_activity row) it belongs to; nil = the card
      column :filename, String, null: false
      column :content_type, String, null: false    # detected from the bytes
      column :size, Integer, null: false
      column :sha256, String, null: false
      column :stored_path, String, null: false
      column :uploaded_by, String, null: false
      column :created_at, Integer, null: false
      column :deleted_at, Integer
      column :deleted_by, String
      index %i[card_id deleted_at]
      index :activity_id
    end
  end

  down do
    drop_table :card_attachments
  end
end
