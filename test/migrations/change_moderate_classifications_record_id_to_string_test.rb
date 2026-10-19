# frozen_string_literal: true

require "test_helper"
require Moderate::Engine.root.join("db/migrate/20261019120000_change_moderate_classifications_record_id_to_string").to_s

# 1.0.1's migration: moderate_classifications.record_id as a string, so apps mixing
# uuid and bigint models record classifications for both. Down and up again on the
# test database, keeping a row. Not transactional: it changes the schema, and leaves
# it as it found it.
class ChangeModerateClassificationsRecordIdToStringTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @migration = ChangeModerateClassificationsRecordIdToString.new
    @migration.verbose = false
  end

  teardown do
    migrate(:up)
    Moderate::Classification.where(field: "photo", digest: %w[a b].map { |c| c * 16 }).delete_all
  end

  test "down restores the key type; up makes record_id a string again, keeping rows, and is idempotent" do
    migrate(:down)
    assert_not_equal :string, record_id_type
    Moderate::Classification.create!(record_type: "Comment", record_id: 42, field: "photo", digest: "a" * 16)

    migrate(:up)
    assert_equal :string, record_id_type
    assert_equal "42", Moderate::Classification.find_by(digest: "a" * 16).record_id
    assert_nothing_raised { migrate(:up) }
  end

  test "a uuid-keyed record and a bigint-keyed record are both classified" do
    uuid = SecureRandom.uuid
    Moderate::Classification.create!(record_type: "Comment", record_id: uuid, field: "photo", digest: "a" * 16)
    Moderate::Classification.create!(record_type: "Comment", record_id: 7, field: "photo", digest: "b" * 16)

    assert_equal [uuid, "7"].sort, Moderate::Classification.where(field: "photo", digest: %w[a b].map { |c| c * 16 }).pluck(:record_id).sort
  end

  private

  def record_id_type
    ActiveRecord::Base.connection.columns(:moderate_classifications).find { |c| c.name == "record_id" }.type
  end

  def migrate(direction)
    @migration.migrate(direction)
    Moderate::Classification.reset_column_information
  end
end
