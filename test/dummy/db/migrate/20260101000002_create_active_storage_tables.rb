# frozen_string_literal: true

# Active Storage's schema, vendored into the dummy so the image-field filtering
# tests can attach a blob to Comment#image. This mirrors the migration Active
# Storage ships (rails active_storage:install) — copied here rather than relying on
# the installer so `db:migrate:reset` has a deterministic, self-contained schema
# across the Rails 7.1 / 7.2 / 8.1 matrix. Pinned to [7.1] (the gemspec floor),
# which every Rails in the matrix accepts.
class CreateActiveStorageTables < ActiveRecord::Migration[7.1]
  def change
    primary_key_type, foreign_key_type = primary_and_foreign_key_types

    create_table :active_storage_blobs, id: primary_key_type do |t|
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.text :metadata
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum

      if connection.supports_datetime_with_precision?
        t.datetime :created_at, precision: 6, null: false
      else
        t.datetime :created_at, null: false
      end

      t.index [:key], unique: true
    end

    create_table :active_storage_attachments, id: primary_key_type do |t|
      t.string :name, null: false
      t.references :record, null: false, polymorphic: true, index: false, type: foreign_key_type
      t.references :blob, null: false, type: foreign_key_type

      if connection.supports_datetime_with_precision?
        t.datetime :created_at, precision: 6, null: false
      else
        t.datetime :created_at, null: false
      end

      t.index [:record_type, :record_id, :name, :blob_id], name: :index_active_storage_attachments_uniqueness, unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end

    create_table :active_storage_variant_records, id: primary_key_type do |t|
      t.belongs_to :blob, null: false, index: false, type: foreign_key_type
      t.string :variation_digest, null: false

      t.index [:blob_id, :variation_digest], name: :index_active_storage_variant_records_uniqueness, unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end
  end

  private

  def primary_and_foreign_key_types
    config = Rails.configuration.generators
    setting = config.options[config.orm][:primary_key_type]
    primary_key_type = setting || :primary_key
    foreign_key_type = setting || :bigint
    [primary_key_type, foreign_key_type]
  end
end
