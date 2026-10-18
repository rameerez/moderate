# frozen_string_literal: true

require "test_helper"
require Moderate::Engine.root.join("db/migrate/20261018200000_add_pending_key_to_moderate_flags").to_s

# beta4's upgrade migration (db/migrate/…_add_pending_key_to_moderate_flags.rb): down
# and up again on the test database, with the rows a beta3 host could have, including
# two pending flags on one content and field. Not transactional: it changes the
# schema, and leaves it as it found it.
class AddPendingKeyToModerateFlagsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @migration = AddPendingKeyToModerateFlags.new
    @migration.verbose = false
    @author = User.create!(name: "Author #{SecureRandom.hex(3)}")
    @comment = Comment.create!(user: @author, body: "x")
    @inserted = []
  end

  teardown do
    Moderate::Flag.where(id: @inserted).delete_all # first: rows a test left could stop the migration
    migrate(:up) # whatever happened, the schema the suite expects
    Moderate::Flag.where(flaggable: @comment).delete_all
    @comment.destroy
    @author.destroy
  end

  test "down removes the column and its index; up adds them back, backfilling, and is idempotent" do
    migrate(:down)
    assert_not connection.column_exists?(:moderate_flags, :pending_key)
    assert_not connection.index_exists?(:moderate_flags, :pending_key, name: AddPendingKeyToModerateFlags::INDEX)

    older = insert_flag(status: "pending", created_at: 2.days.ago)
    newer = insert_flag(status: "pending", created_at: 1.day.ago) # a beta3 duplicate
    closed = insert_flag(status: "dismissed", created_at: 3.days.ago)

    migrate(:up)
    assert connection.index_exists?(:moderate_flags, :pending_key, unique: true, name: AddPendingKeyToModerateFlags::INDEX)
    keys = Moderate::Flag.where(id: [older, newer, closed]).pluck(:id, :pending_key).to_h
    assert_equal "Comment/#{@comment.id}/body", keys[newer], "the newest pending flag on the field takes the key"
    assert_nil keys[older], "an older duplicate stays pending without one"
    assert_nil keys[closed]

    assert_nothing_raised { migrate(:up) }
  end

  test "types that differ only by case each keep their key: the column compares bytes" do
    migrate(:down)
    lower = insert_flag(status: "pending", created_at: 1.day.ago)
    upper = insert_flag(status: "pending", created_at: 1.day.ago, type: "COMMENT")

    migrate(:up)
    keys = Moderate::Flag.where(id: [lower, upper]).pluck(:id, :pending_key).to_h
    assert_equal "Comment/#{@comment.id}/body", keys[lower]
    assert_equal "COMMENT/#{@comment.id}/body", keys[upper]
    assert_equal "utf8mb4_bin", pending_key_column.collation if mysql?
  end

  test "keys the database would treat as one stop the migration, naming them, before the index" do
    migrate(:down)
    connection.add_column :moderate_flags, :pending_key, :string # no byte comparison asked for
    Moderate::Flag.reset_column_information
    key = "Comment/#{@comment.id}/body"
    first = insert_flag(status: "pending", created_at: 2.days.ago, pending_key: key)
    second = insert_flag(status: "pending", created_at: 1.day.ago, pending_key: key)

    error = assert_raises(ActiveRecord::MigrationError) { migrate(:up) }
    assert_includes error.message, key.inspect
    assert_includes error.message, "flags #{first}, #{second}"
    assert_not connection.index_exists?(:moderate_flags, :pending_key, name: AddPendingKeyToModerateFlags::INDEX)
    assert_equal "utf8mb4_bin", pending_key_column.collation, "converted before refusing" if mysql?
  end

  private

  def mysql? = connection.adapter_name.downcase.match?(/mysql|trilogy/)

  def pending_key_column
    connection.columns(:moderate_flags).find { |column| column.name == "pending_key" }
  end

  def connection = ActiveRecord::Base.connection

  def migrate(direction)
    @migration.migrate(direction)
    Moderate::Flag.reset_column_information
  end

  def insert_flag(status:, created_at:, type: "Comment", pending_key: nil)
    row = {
      flaggable_type: type, flaggable_id: @comment.id, field: "body", source: "manual", mode: "flag",
      status: status, resolution_note: (status == "pending" ? nil : "closed"),
      categories: [], scores: {}, context: {}, created_at: created_at, updated_at: created_at
    }
    row[:pending_key] = pending_key if pending_key
    Moderate::Flag.insert_all!([row])
    Moderate::Flag.where(flaggable_id: @comment.id, flaggable_type: type).order(:id).last.id.tap { |id| @inserted << id }
  end
end
