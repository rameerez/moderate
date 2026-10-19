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
    migrate(:up) # the schema the suite expects, whatever ran before
  end

  teardown do
    migrate(:up)
    Moderate::Classification.where(field: "photo", digest: %w[a b c].map { |c| c * 16 }).delete_all
  end

  test "down refuses while a row holds an id of the other key kind, naming how many; after deleting it, down works" do
    Moderate::Classification.create!(record_type: "Comment", record_id: SecureRandom.uuid, field: "photo", digest: "c" * 16)

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
    assert_match "1 moderate_classifications row(s)", error.message
    assert_match "Delete those classification rows first", error.message
    assert_equal :string, record_id_type, "nothing changed"

    Moderate::Classification.where(digest: "c" * 16).delete_all
    migrate(:down)
    assert_not_equal :string, record_id_type
  end

  test "a negative bigint id fits: the rollback keeps it" do
    Moderate::Classification.create!(record_type: "Comment", record_id: "-5", field: "photo", digest: "c" * 16)

    migrate(:down)

    assert_equal(-5, Moderate::Classification.find_by(digest: "c" * 16).record_id)
  end

  test "a decimal id beyond the signed 64-bit range is refused, with the count" do
    Moderate::Classification.create!(record_type: "Comment", record_id: (2**63).to_s, field: "photo", digest: "c" * 16)

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
    assert_match "1 moderate_classifications row(s)", error.message
    assert_equal :string, record_id_type
  end

  test "in a uuid-keyed app, a canonical uuid of either case fits and a bigint-looking id is refused" do
    @migration.stubs(:key_type_setting).returns(:uuid)
    assert @migration.send(:fits?, SecureRandom.uuid.upcase, :uuid)
    assert @migration.send(:fits?, SecureRandom.uuid, :uuid)
    assert_not @migration.send(:fits?, "{#{SecureRandom.uuid}}", :uuid)
    Moderate::Classification.create!(record_type: "Comment", record_id: "42", field: "photo", digest: "c" * 16)

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
    assert_match "isn't a uuid id", error.message
    assert_equal :string, record_id_type
  end

  test "on MySQL record_id compares bytewise" do
    unless ActiveRecord::Base.connection.adapter_name.downcase.match?(/mysql|trilogy/)
      skip "MySQL only: elsewhere a string column compares bytes"
    end

    column = ActiveRecord::Base.connection.columns(:moderate_classifications).find { |c| c.name == "record_id" }
    assert_equal "utf8mb4_bin", column.collation
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
