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
  end

  teardown do
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

  private

  def connection = ActiveRecord::Base.connection

  def migrate(direction)
    @migration.migrate(direction)
    Moderate::Flag.reset_column_information
  end

  def insert_flag(status:, created_at:)
    row = {
      flaggable_type: "Comment", flaggable_id: @comment.id, field: "body", source: "manual", mode: "flag",
      status: status, resolution_note: (status == "pending" ? nil : "closed"),
      categories: [], scores: {}, context: {}, created_at: created_at, updated_at: created_at
    }
    Moderate::Flag.insert_all!([row])
    Moderate::Flag.where(flaggable: @comment).order(:id).last.id
  end
end
