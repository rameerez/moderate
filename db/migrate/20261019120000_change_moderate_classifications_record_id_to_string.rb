# frozen_string_literal: true

# 1.0.1: moderate_classifications.record_id becomes a string, so an app that mixes
# uuid and bigint primary keys records classifications for every kind of record (1.0.0
# created it with the app's one primary-key type). `digest` (always 16 hex characters)
# and `record_id` (a uuid is 36, a bigint at most 20) are capped at 64 characters, so
# the unique index on (record_type, record_id, field, digest) stays within MySQL's
# 3072-byte key limit.
#
# Ships with the gem: `rails generate moderate:install` copies it after the others,
# an app holding copies gets it with `bin/rails moderate:install:migrations`, and an
# app without copies gets it through the engine. Guarded, so it is a no-op when the
# column is already a string, and reversible: `down` turns record_id back into the
# app's primary-key type, which fails if rows of the other key kind exist (they are
# bookkeeping only; delete them first).
class ChangeModerateClassificationsRecordIdToString < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:moderate_classifications)
    return if column_type(:record_id) == :string

    change_column :moderate_classifications, :digest, :string, limit: 64, null: false
    change_column :moderate_classifications, :record_id, :string, limit: 64, null: false, **cast("varchar")
  end

  def down
    return unless table_exists?(:moderate_classifications)
    return unless column_type(:record_id) == :string

    key_type = key_type_setting || :bigint
    change_column :moderate_classifications, :record_id, key_type, null: false, **cast(key_type == :uuid ? "uuid" : "bigint")
    change_column :moderate_classifications, :digest, :string, null: false
  end

  private

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
