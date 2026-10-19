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
#   moderate_reports.covered_by_report_id
#                                  the decision that removed this report's content while
#                                  it was pending (stamped by that decision, under the
#                                  content's lock); only such a report is closed as
#                                  "already removed by" it.
#   moderate_classifications       one row per record, field and set of attached
#                                  files: who is classifying it (a claim) and when it
#                                  was classified (Moderate::Attachments). Ids, a
#                                  digest of blob ids and timestamps; no content.
#
# The one migration that creates all of this, in a fresh app as in an upgraded one:
# `rails generate moderate:install` copies it after create_moderate_tables (which
# leaves it out), an app holding copies gets it with `bin/rails
# moderate:install:migrations`, and an app installed without copies gets it through
# the engine, which adds the gem's db/migrate to its paths. Its `down` drops only what
# it created. Guarded, so a second run is a no-op. No backfill: nothing was redacted,
# held or claimed before 1.0.
class AddRetentionAndClassificationsToModerateTables < ActiveRecord::Migration[8.0]
  COLUMNS = {
    moderate_reports: %i[redacted_at held_until],
    moderate_flags: %i[redacted_at],
    moderate_appeals: %i[redacted_at]
  }.freeze
  HOLD_INDEX = "index_moderate_reports_on_held_until"
  COVERED_INDEX = "index_moderate_reports_on_covered_by_report_id"
  CLASSIFICATION_INDEX = "index_moderate_classifications_on_record_field_digest"

  def up
    COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      columns.each { |column| add_column table, column, :datetime unless column_exists?(table, column) }
    end
    if table_exists?(:moderate_reports) && !index_exists?(:moderate_reports, :held_until, name: HOLD_INDEX)
      add_index :moderate_reports, :held_until, name: HOLD_INDEX
    end
    add_covered_by if table_exists?(:moderate_reports)

    create_classifications unless table_exists?(:moderate_classifications)
  end

  def down
    drop_table :moderate_classifications if table_exists?(:moderate_classifications)
    if table_exists?(:moderate_reports) && column_exists?(:moderate_reports, :covered_by_report_id)
      remove_index :moderate_reports, name: COVERED_INDEX if index_exists?(:moderate_reports, :covered_by_report_id, name: COVERED_INDEX)
      remove_column :moderate_reports, :covered_by_report_id
    end
    if table_exists?(:moderate_reports) && index_exists?(:moderate_reports, :held_until, name: HOLD_INDEX)
      remove_index :moderate_reports, name: HOLD_INDEX
    end

    COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      columns.each { |column| remove_column table, column if column_exists?(table, column) }
    end
  end

  private

  def add_covered_by
    _primary_key_type, foreign_key_type = key_types
    add_column :moderate_reports, :covered_by_report_id, foreign_key_type unless column_exists?(:moderate_reports, :covered_by_report_id)
    return if index_exists?(:moderate_reports, :covered_by_report_id, name: COVERED_INDEX)

    add_index :moderate_reports, :covered_by_report_id, name: COVERED_INDEX
  end

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
    [ setting || :primary_key, setting || :bigint ]
  end
end
