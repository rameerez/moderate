# frozen_string_literal: true

# 1.0.0.beta4: at most one PENDING flag per content and field, enforced by the
# database. `pending_key` ("<flaggable_type>/<flaggable_id>/<field>") is set while a
# flag is pending and NULL once it is closed (Moderate::Flag keeps it in sync on every
# save); a UNIQUE index on it lets only one pending flag per content + field exist,
# and NULLs never collide (PostgreSQL, MySQL and SQLite alike). Flag.flag! and
# Flag.flag_for_review! insert and, on the collision, return the flag already waiting.
#
# Ships with the gem and runs with `bin/rails db:migrate`: the engine adds the gem's
# db/migrate to your app's migration paths. Guarded both ways, so it is a no-op on a
# fresh install (the install generator's table already has the column) and safe to
# run twice. Backfill: each content + field's NEWEST pending flag takes the key; older
# duplicate pending flags (possible before this release) stay pending without one.
#
# The key compares as BYTES on every database: on MySQL the column is declared
# utf8mb4_bin, because the default collation is case-insensitive and would make
# "Post/1/body" and "POST/1/body" one key (PostgreSQL and SQLite compare strings
# byte-wise already). Before adding the index, keys the database would still treat as
# one (grouped by the database itself, under the column's collation) stop the
# migration with a message naming them, instead of an index error.
class AddPendingKeyToModerateFlags < ActiveRecord::Migration[7.1]
  INDEX = "index_moderate_flags_on_pending_key"

  # The table as it is, not the app's model: a migration must not depend on code.
  class Flag < ActiveRecord::Base
    self.table_name = "moderate_flags"
  end

  def up
    return unless table_exists?(:moderate_flags)

    if column_exists?(:moderate_flags, :pending_key)
      compare_pending_keys_as_bytes
    else
      add_column :moderate_flags, :pending_key, :string, **pending_key_options
    end
    backfill_pending_keys
    refuse_duplicate_pending_keys
    return if index_exists?(:moderate_flags, :pending_key, name: INDEX)

    add_index :moderate_flags, :pending_key, unique: true, name: INDEX
  end

  def down
    return unless table_exists?(:moderate_flags)

    remove_index :moderate_flags, name: INDEX if index_exists?(:moderate_flags, :pending_key, name: INDEX)
    remove_column :moderate_flags, :pending_key if column_exists?(:moderate_flags, :pending_key)
  end

  private

  BINARY_COLLATION = "utf8mb4_bin"

  # MySQL under either of Rails' adapters: mysql2, or Trilogy.
  def mysql?
    connection.adapter_name.downcase.match?(/mysql|trilogy/)
  end

  def pending_key_options
    mysql? ? { collation: BINARY_COLLATION } : {}
  end

  # A column added without the collation (by hand, or by an earlier draft of this
  # migration): give it byte comparison. Relaxing a collation never makes two
  # distinct keys equal, so an existing unique index stays valid.
  def compare_pending_keys_as_bytes
    return unless mysql?

    column = connection.columns(:moderate_flags).find { |c| c.name == "pending_key" }
    return if column.collation == BINARY_COLLATION

    change_column :moderate_flags, :pending_key, :string, collation: BINARY_COLLATION
  end

  def refuse_duplicate_pending_keys
    duplicates = Flag.where.not(pending_key: nil).group(:pending_key).having("COUNT(*) > 1").count.keys
    return if duplicates.empty?

    listed = duplicates.map { |key| "#{key.inspect} (flags #{Flag.where(pending_key: key).order(:id).ids.join(", ")})" }
    raise ActiveRecord::MigrationError, <<~MESSAGE.squish
      moderate_flags has pending flags whose pending_key the unique index would treat as
      one: #{listed.join("; ")}. Close all but one of each (dismiss them, or set
      pending_key to NULL on the older ones), then run the migration again.
    MESSAGE
  end

  def backfill_pending_keys
    Flag.reset_column_information
    newest = {}
    Flag.where(status: "pending", pending_key: nil).select(:id, :flaggable_type, :flaggable_id, :field, :created_at)
        .find_each do |flag|
      key = "#{flag.flaggable_type}/#{flag.flaggable_id}/#{flag.field}"
      newest[key] = flag if newest[key].nil? || flag.created_at > newest[key].created_at
    end
    taken = Flag.where(pending_key: newest.keys).pluck(:pending_key).to_set
    newest.each do |key, flag|
      Flag.where(id: flag.id).update_all(pending_key: key) unless taken.include?(key)
    end
  end
end
