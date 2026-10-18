# frozen_string_literal: true

# 1.0.0.beta4: at most one PENDING flag per content and field, enforced by the
# database. `pending_key` ("<flaggable_type>/<flaggable_id>/<field>") is set while a
# flag is pending and NULL once it is closed (Moderate::Flag keeps it in sync on every
# save); a UNIQUE index on it lets only one pending flag per content + field exist,
# and NULLs never collide (PostgreSQL, MySQL and SQLite alike). Flag.flag! and
# Flag.flag_for_review! insert and, on the collision, return the flag already waiting.
#
# THE ONE MIGRATION THAT CREATES pending_key, in every app. A fresh install gets it
# from `bin/rails generate moderate:install`, copied right after create_moderate_tables
# (as "<number>_add_pending_key_to_moderate_flags.moderate.rb"); an app upgrading from
# beta3 gets it through the engine, which adds the gem's db/migrate to the app's
# migration paths unless the app holds copies. Safe to run twice.
#
# The key compares as bytes: on MySQL the column is utf8mb4_bin, because the default
# collation ignores case and would make "Post/1/body" and "POST/1/body" one key
# (PostgreSQL and SQLite compare bytes already). utf8mb4_bin still ignores TRAILING
# spaces (PAD SPACE); Moderate::Flag strips `field`, so keys it builds never differ by
# them.
#
# Backfill: each content + field's NEWEST pending flag takes the key; older duplicate
# pending flags (possible before this release) stay pending without one. The keys are
# checked by the database before any is written, grouped under the column's own
# collation: keys it would treat as one though they differ as strings (legacy rows
# whose field has trailing spaces, on MySQL) stop the migration, naming the flags.
#
# `down` drops the index and the column: this migration is the only thing that creates
# them, so rolling it back leaves create_moderate_tables' schema exactly as it was.
class AddPendingKeyToModerateFlags < ActiveRecord::Migration[7.1]
  INDEX = "index_moderate_flags_on_pending_key"
  BINARY_COLLATION = "utf8mb4_bin"
  CHECK_TABLE = "moderate_pending_key_check"

  # The tables as they are, not the app's model: a migration must not depend on code.
  class Flag < ActiveRecord::Base
    self.table_name = "moderate_flags"
  end

  def up
    return unless table_exists?(:moderate_flags)

    if column_exists?(:moderate_flags, :pending_key)
      require_binary_comparison
    else
      add_column :moderate_flags, :pending_key, :string, **pending_key_options
    end
    backfill_pending_keys
    return if index_exists?(:moderate_flags, :pending_key, name: INDEX)

    add_index :moderate_flags, :pending_key, unique: true, name: INDEX
  end

  def down
    return unless table_exists?(:moderate_flags)

    remove_index :moderate_flags, name: INDEX if index_exists?(:moderate_flags, :pending_key, name: INDEX)
    remove_column :moderate_flags, :pending_key if column_exists?(:moderate_flags, :pending_key)
  end

  private

  # MySQL under either of Rails' adapters: mysql2, or Trilogy.
  def mysql?
    connection.adapter_name.downcase.match?(/mysql|trilogy/)
  end

  def pending_key_options
    mysql? ? { collation: BINARY_COLLATION } : {}
  end

  # Only this migration creates the column, binary. One that isn't was made some other
  # way: say so, rather than altering it here.
  def require_binary_comparison
    return unless mysql?

    collation = connection.columns(:moderate_flags).find { |c| c.name == "pending_key" }.collation
    return if collation == BINARY_COLLATION

    raise ActiveRecord::MigrationError, <<~MESSAGE.squish
      moderate_flags.pending_key compares with #{collation.inspect}, which ignores case, so
      flags on content types that differ only by case would share one key. Make it
      binary, then run the migration again: ALTER TABLE moderate_flags MODIFY pending_key
      VARCHAR(255) COLLATE #{BINARY_COLLATION} NULL
    MESSAGE
  end

  def backfill_pending_keys
    Flag.reset_column_information
    chosen = newest_pending_without_key
    refuse_keys_the_database_would_merge(chosen)
    chosen.each { |id, key| Flag.where(id: id).update_all(pending_key: key) }
  end

  # { flag id => key } for each content + field's newest pending flag without a key,
  # unless a flag already holds that exact key.
  def newest_pending_without_key
    newest = {}
    Flag.where(status: "pending", pending_key: nil).select(:id, :flaggable_type, :flaggable_id, :field, :created_at)
      .find_each do |flag|
      key = "#{flag.flaggable_type}/#{flag.flaggable_id}/#{flag.field}"
      newest[key] = flag if newest[key].nil? || flag.created_at > newest[key].created_at
    end
    taken = Flag.where.not(pending_key: nil).pluck(:pending_key).to_set
    newest.except(*taken).to_h { |key, flag| [flag.id, key] }
  end

  # The keys to write and the keys already written, in a temporary table whose key
  # column compares exactly as pending_key does; any key the database groups twice
  # would make the index (or a backfill UPDATE) fail, so stop first and name them.
  # Plain SQL: Rails' schema lookups don't all see temporary tables (PostgreSQL's pg_temp).
  def refuse_keys_the_database_would_merge(chosen)
    create_table CHECK_TABLE, temporary: true, id: false do |t|
      t.bigint :flag_id, null: false
      t.string :pending_key, null: false, **pending_key_options
    end
    table = quote_table_name(CHECK_TABLE)
    rows = chosen.to_a + Flag.where.not(pending_key: nil).pluck(:id, :pending_key)
    rows.each_slice(500) do |slice|
      values = slice.map { |id, key| "(#{Integer(id)}, #{quote(key)})" }.join(", ")
      execute "INSERT INTO #{table} (flag_id, pending_key) VALUES #{values}"
    end

    merged = select_values("SELECT pending_key FROM #{table} GROUP BY pending_key HAVING COUNT(*) > 1")
    return if merged.empty?

    listed = merged.map do |key|
      ids = select_values("SELECT flag_id FROM #{table} WHERE pending_key = #{quote(key)} ORDER BY flag_id")
      "#{key.inspect} (flags #{ids.map { |id| Integer(id) }.join(", ")})"
    end
    raise ActiveRecord::MigrationError, <<~MESSAGE.squish
      moderate_flags has pending flags whose pending_key the unique index would treat as
      one: #{listed.join("; ")}. Close all but one of each (dismiss them, or fix a field
      with stray spaces), then run the migration again.
    MESSAGE
  ensure
    drop_table CHECK_TABLE, temporary: true, if_exists: true
  end
end
