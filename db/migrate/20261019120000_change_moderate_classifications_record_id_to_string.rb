# frozen_string_literal: true

# 1.0.1: moderate_classifications.record_id becomes a string, so an app that mixes
# uuid and bigint primary keys records classifications for every kind of record (1.0.0
# created it with the app's one primary-key type). `digest` (always 16 hex characters)
# and `record_id` (a uuid is 36, a bigint at most 20) are capped at 64 characters, so
# the unique index on (record_type, record_id, field, digest) stays within MySQL's
# 3072-byte key limit.
#
# On MySQL (and Trilogy) record_id is utf8mb4_bin, so ids compare bytewise, as they do
# on PostgreSQL and SQLite: "abc" and "ABC" are two records.
#
# Ships with the gem: `rails generate moderate:install` copies it after the others,
# an app holding copies gets it with `bin/rails moderate:install:migrations`, and an
# app without copies gets it through the engine. Guarded, so it is a no-op when the
# column is already a string, and reversible: `down` turns record_id back into the
# app's primary-key type, and first refuses (naming how many) if any row holds an id
# of the other key kind, which that type can't keep.
class ChangeModerateClassificationsRecordIdToString < ActiveRecord::Migration[8.0]
  # The table as it is, not the app's model: a migration must not depend on code.
  class Classification < ActiveRecord::Base
    self.table_name = "moderate_classifications"
  end

  # The canonical 8-4-4-4-12 form, either case: what Rails writes for a uuid key. (Other
  # forms PostgreSQL accepts as uuid input, braces or no hyphens, aren't expected here.)
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/i
  BIGINT = /\A-?\d+\z/
  BIGINT_RANGE = (-(2**63))..((2**63) - 1)

  def up
    return unless table_exists?(:moderate_classifications)
    return if column_type(:record_id) == :string

    change_column :moderate_classifications, :digest, :string, limit: 64, null: false
    change_column :moderate_classifications, :record_id, :string, limit: 64, null: false, **binary, **cast("varchar")
  end

  def down
    return unless table_exists?(:moderate_classifications)
    return unless column_type(:record_id) == :string

    key_type = key_type_setting || :bigint
    refuse_unfit_ids!(key_type)
    change_column :moderate_classifications, :record_id, key_type, null: false, **cast(key_type == :uuid ? "uuid" : "bigint")
    change_column :moderate_classifications, :digest, :string, null: false
  end

  private

  # Rows whose record_id the app's key type can't hold (a uuid in a bigint app, or the
  # reverse): rolling back would fail midway on PostgreSQL and MySQL, or keep the text
  # in an integer column on SQLite.
  def refuse_unfit_ids!(key_type)
    unfit = unfit_ids_count(key_type)
    return if unfit.zero?

    raise ActiveRecord::IrreversibleMigration,
      "#{unfit} moderate_classifications row(s) hold a record_id that isn't a #{key_type} id, so record_id " \
      "can't go back to #{key_type}. Delete those classification rows first; they are bookkeeping, " \
      "re-created on the next classification."
  end

  def unfit_ids_count(key_type)
    Classification.reset_column_information
    unfit = 0
    Classification.in_batches(of: 1000) do |batch|
      unfit += batch.pluck(:record_id).count { |id| !fits?(id.to_s, key_type) }
    end
    unfit
  end

  # A uuid in the canonical form; a bigint: an optionally negative integer within the
  # signed 64-bit range (a longer one would fail the conversion, not this refusal).
  def fits?(id, key_type)
    return UUID.match?(id) if key_type == :uuid

    BIGINT.match?(id) && BIGINT_RANGE.cover?(id.to_i)
  end

  def mysql?
    connection.adapter_name.downcase.match?(/mysql|trilogy/)
  end

  # Bytewise comparison on MySQL, whose default collation ignores case.
  def binary
    mysql? ? { collation: "utf8mb4_bin" } : {}
  end

  def column_type(name)
    connection.columns(:moderate_classifications).find { |column| column.name == name.to_s }&.type
  end

  # PostgreSQL needs the conversion spelled out; MySQL and SQLite convert by themselves.
  def cast(type)
    connection.adapter_name.downcase.include?("postg") ? { using: "record_id::#{type}" } : {}
  end

  def key_type_setting
    config = Rails.configuration.generators
    config.options[config.orm][:primary_key_type]
  end
end
