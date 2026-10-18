# frozen_string_literal: true

# 1.0.0: what retention, the appeal window and attachment classification need.
#
#   moderate_reports.redacted_at   when Moderate.purge removed the report's personal
#   moderate_flags.redacted_at     data (nil: never). The purge selects on this, never
#   moderate_appeals.redacted_at   on the content, so a message that literally reads
#                                  "[redacted]" is still purged.
#   moderate_reports.held_until    a legal hold (Moderate.hold): until then the purge
#                                  leaves the report, its appeals and the flags on its
#                                  content alone.
#   moderate_classifications       one row per record, field and set of attached
#                                  files: who is classifying it (a claim) and when it
#                                  was classified (Moderate::Attachments). Ids, a
#                                  digest of blob ids and timestamps; no content.
#
# Ships with the gem and runs with `bin/rails db:migrate`: the engine adds the gem's
# db/migrate to your app's migration paths. Guarded both ways, so it is a no-op on a
# fresh install (the install generator's tables already have all of this) and safe to
# run twice. No backfill: nothing was redacted, held or claimed before 1.0.
class AddRetentionAndClassificationsToModerateTables < ActiveRecord::Migration[8.0]
  COLUMNS = {
    moderate_reports: %i[redacted_at held_until],
    moderate_flags: %i[redacted_at],
    moderate_appeals: %i[redacted_at]
  }.freeze
  HOLD_INDEX = "index_moderate_reports_on_held_until"
  CLASSIFICATION_INDEX = "index_moderate_classifications_on_record_field_digest"

  def up
    COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      columns.each { |column| add_column table, column, :datetime unless column_exists?(table, column) }
    end
    if table_exists?(:moderate_reports) && !index_exists?(:moderate_reports, :held_until, name: HOLD_INDEX)
      add_index :moderate_reports, :held_until, name: HOLD_INDEX
    end

    create_classifications unless table_exists?(:moderate_classifications)
  end

  def down
    drop_table :moderate_classifications if table_exists?(:moderate_classifications)
    if table_exists?(:moderate_reports) && index_exists?(:moderate_reports, :held_until, name: HOLD_INDEX)
      remove_index :moderate_reports, name: HOLD_INDEX
    end

    COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      columns.each { |column| remove_column table, column if column_exists?(table, column) }
    end
  end

  private

  def create_classifications
    primary_key_type, foreign_key_type = key_types
    create_table :moderate_classifications, id: primary_key_type do |t|
      t.references :record, polymorphic: true, type: foreign_key_type, null: false, index: false
      t.string :field, null: false
      t.string :digest, null: false
      t.string :claimed_by
      t.datetime :claimed_at
      t.datetime :classified_at
      t.string :adapter
      t.boolean :flagged
      t.timestamps
    end
    add_index :moderate_classifications, %i[record_type record_id field digest], unique: true, name: CLASSIFICATION_INDEX
    add_index :moderate_classifications, :classified_at, name: "index_moderate_classifications_on_classified_at"
  end

  # The app's primary-key type, as the install generator reads it (uuid or bigint).
  def key_types
    config = Rails.configuration.generators
    setting = config.options[config.orm][:primary_key_type]
    [setting || :primary_key, setting || :bigint]
  end
end
