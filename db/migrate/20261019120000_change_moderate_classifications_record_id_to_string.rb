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

  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  BIGINT = /\A\d+\z/

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
    fits = key_type == :uuid ? UUID : BIGINT
    Classification.reset_column_information
    unfit = 0
    Classification.in_batches(of: 1000) do |batch|
      unfit += batch.pluck(:record_id).count { |id| !fits.match?(id.to_s) }
    end
    return if unfit.zero?

    raise ActiveRecord::IrreversibleMigration,
      "#{unfit} moderate_classifications row(s) hold a record_id that isn't a #{key_type} id, so record_id " \
      "can't go back to #{key_type}. Delete those classification rows first; they are bookkeeping, " \
      "re-created on the next classification."
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
