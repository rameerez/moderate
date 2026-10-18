# frozen_string_literal: true

require "test_helper"
require Moderate::Engine.root.join("db/migrate/20261018210000_add_retention_and_classifications_to_moderate_tables").to_s

# 1.0's upgrade migration (db/migrate/…_add_retention_and_classifications_to_moderate_tables.rb):
# down and up again on the test database, with a row a beta host has. Not
# transactional: it changes the schema, and leaves it as it found it.
class AddRetentionAndClassificationsToModerateTablesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  MIGRATION = AddRetentionAndClassificationsToModerateTables

  setup do
    @migration = MIGRATION.new
    @migration.verbose = false
  end

  teardown do
    migrate(:up) # whatever happened, the schema the suite expects
  end

  test "down removes the columns, the hold index and the classifications table; up adds them back, keeping rows" do
    migrate(:down)
    assert_not connection.table_exists?(:moderate_classifications)
    MIGRATION::COLUMNS.each do |table, columns|
      columns.each { |column| assert_not connection.column_exists?(table, column), "#{table}.#{column}" }
    end
    assert_not connection.index_exists?(:moderate_reports, :held_until, name: MIGRATION::HOLD_INDEX)

    author = User.create!(name: "Author #{SecureRandom.hex(3)}", email: "a#{SecureRandom.hex(3)}@example.com")
    comment = Comment.create!(user: author, body: "x")
    flag_id = Moderate::Flag.insert_all!([{
      flaggable_type: "Comment", flaggable_id: comment.id, field: "body", source: "manual", mode: "flag",
      status: "pending", categories: [], scores: {}, context: {}, created_at: Time.current, updated_at: Time.current
    }]).rows.flatten.first || Moderate::Flag.where(flaggable_type: "Comment", flaggable_id: comment.id).pick(:id)

    migrate(:up)
    MIGRATION::COLUMNS.each do |table, columns|
      columns.each { |column| assert connection.column_exists?(table, column, :datetime), "#{table}.#{column}" }
    end
    assert connection.index_exists?(:moderate_reports, :held_until, name: MIGRATION::HOLD_INDEX)
    assert connection.table_exists?(:moderate_classifications)
    assert connection.index_exists?(:moderate_classifications, %i[record_type record_id field digest],
      unique: true, name: MIGRATION::CLASSIFICATION_INDEX)
    assert_nil Moderate::Flag.find(flag_id).redacted_at, "existing rows are neither redacted nor held"

    assert_nothing_raised { migrate(:up) }
  ensure
    Moderate::Flag.where(flaggable_type: "Comment", flaggable_id: comment&.id).delete_all
    comment&.destroy
    author&.destroy
  end

  private

  def connection = ActiveRecord::Base.connection

  def migrate(direction)
    @migration.migrate(direction)
    [Moderate::Report, Moderate::Flag, Moderate::Appeal, Moderate::Classification].each(&:reset_column_information)
  end
end
