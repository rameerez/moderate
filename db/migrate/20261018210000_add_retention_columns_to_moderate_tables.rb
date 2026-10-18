# frozen_string_literal: true

# 1.0.0: what retention and the appeal window need to know about each record.
#
#   moderate_reports.redacted_at   when Moderate.purge removed the report's personal
#   moderate_flags.redacted_at     data (nil: never). The purge selects on this, never
#   moderate_appeals.redacted_at   on the content, so a message that literally reads
#                                  "[redacted]" is still purged.
#   moderate_reports.held_until    a legal hold (Moderate.hold): until then the purge
#                                  leaves the report, its appeals and the flags on its
#                                  content alone.
#
# Ships with the gem and runs with `bin/rails db:migrate`: the engine adds the gem's
# db/migrate to your app's migration paths. Guarded both ways, so it is a no-op on a
# fresh install (the install generator's tables already have the columns) and safe to
# run twice. No backfill: nothing was redacted or held before 1.0.
class AddRetentionColumnsToModerateTables < ActiveRecord::Migration[8.0]
  COLUMNS = {
    moderate_reports: %i[redacted_at held_until],
    moderate_flags: %i[redacted_at],
    moderate_appeals: %i[redacted_at]
  }.freeze
  HOLD_INDEX = "index_moderate_reports_on_held_until"

  def up
    COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      columns.each { |column| add_column table, column, :datetime unless column_exists?(table, column) }
    end
    return unless table_exists?(:moderate_reports)
    return if index_exists?(:moderate_reports, :held_until, name: HOLD_INDEX)

    add_index :moderate_reports, :held_until, name: HOLD_INDEX
  end

  def down
    if table_exists?(:moderate_reports) && index_exists?(:moderate_reports, :held_until, name: HOLD_INDEX)
      remove_index :moderate_reports, name: HOLD_INDEX
    end

    COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      columns.each { |column| remove_column table, column if column_exists?(table, column) }
    end
  end
end
