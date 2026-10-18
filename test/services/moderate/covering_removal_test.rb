# frozen_string_literal: true

require "test_helper"

# A second report on content an earlier decision already removed: it closes against
# that decision ("already removed by the decision on Report #X"), the reporter told
# the content is gone, and nothing is removed, announced or stated a second time.
# Only a report that was pending, with the same snapshot text, when the decision
# removed the content is stamped (covered_by_report_id) and so covered: no clocks.
class Moderate::CoveringRemovalTest < ActiveSupport::TestCase
  setup do
    Moderate.configure do |config|
      config.audit = ->(event) { ModerateTestRecorder.audit(event) }
      config.notify = ->(event) { ModerateTestRecorder.notify(event) }
    end
    ModerateTestRecorder.clear
    @moderator = User.create!(name: "Mod", email: "mod@example.com")
    @author = User.create!(name: "Author", email: "author@example.com")
    @comment = Comment.create!(user: @author, body: "vile words")
    @first = User.create!(name: "First", email: "first@example.com").report!(@comment, category: :harassment, field: :body)
    @second = User.create!(name: "Second", email: "second@example.com").report!(@comment, category: :harassment, field: :body)
  end

  def remove_through(report)
    comment = report.reportable
    comment.define_singleton_method(:remove_reported_field!) { |_field| update_column(:body, "") && true }
    report.stubs(:reportable).returns(comment)
    report.resolve!(by: @moderator, note: "Harassment", remove_content: true)
  end

  test "the second report closes against the first decision's removal" do
    remove_through(@first)
    ModerateTestRecorder.clear

    assert_equal @first.id, @second.reload.covered_by_report_id, "stamped by the decision that removed it"
    @second.resolve!(by: @moderator, note: "Same content", remove_content: true)

    @second.reload
    assert_predicate @second, :actioned?
    assert_equal @first.id, @second.resolution_actions["content_already_removed_by"]
    assert_equal "content_removed", @second.decision_visibility
    assert_empty ModerateTestRecorder.audits_named(:content_removed), "nothing removed a second time"
    assert_empty ModerateTestRecorder.notifications_named(:content_removed)
    assert_empty ModerateTestRecorder.notifications_named(:affected_user_decision), "the author was told once, by the first"

    told = ModerateTestRecorder.notifications_named(:report_decision).sole
    assert_equal @first.id, told.payload[:content_already_removed_by]
    assert_match "already removed by the decision on Report ##{@first.id}", told.summary
  end

  test "a recorded removal doesn't cover content that is still there" do
    remove_through(@first)
    @comment.update_column(:body, "back again") # restored, edited, never really gone

    assert_raises(ActiveRecord::RecordInvalid) do
      @second.resolve!(by: @moderator, note: "Same content", remove_content: true)
    end
    assert_predicate @second.reload, :open?
  end

  test "content deleted after the first decision still counts as gone" do
    remove_through(@first)
    @comment.destroy # the report's pointer is nullified; the snapshot keeps the ids

    @second.reload.resolve!(by: @moderator, note: "Same content", remove_content: true)

    assert_equal @first.id, @second.reload.resolution_actions["content_already_removed_by"]
  end

  test "a report whose content was deleted can still be decided" do
    @comment.destroy

    @second.reload.dismiss!(by: @moderator, note: "The content is gone")

    assert_predicate @second.reload, :dismissed?
  end

  test "a repost into the same field is new content: an old removal is not credited for it" do
    remove_through(@first) # the original post is removed
    travel 1.minute
    @comment.update!(body: "vile words") # the author posts the same words again
    repost_report = User.create!(name: "Third", email: "third@example.com").report!(@comment, category: :harassment, field: :body)
    @comment.update_column(:body, "") # and that repost goes too (deleted by its author, say)

    assert_raises(ActiveRecord::RecordInvalid) do
      repost_report.resolve!(by: @moderator, note: "Repost", remove_content: true)
    end
    assert_nil repost_report.reload.resolution_actions["content_already_removed_by"]
  end

  test "a report filed after the removal, on a repost written with update_column, is not covered" do
    remove_through(@first)
    @comment.update_column(:body, "vile words") # the same words again, no updated_at change
    after = User.create!(name: "Third", email: "third@example.com").report!(@comment, category: :harassment, field: :body)
    @comment.update_column(:body, "") # and gone again

    error = assert_raises(ActiveRecord::RecordInvalid) do
      after.resolve!(by: @moderator, note: "Repost", remove_content: true)
    end
    assert_match "Nothing was removed", error.message
    assert_nil after.reload.resolution_actions["content_already_removed_by"]
  end

  test "a report filed after the removal, on content still gone, is refused: nothing is left to remove" do
    remove_through(@first)
    after = User.create!(name: "Third", email: "third@example.com").report!(@comment, category: :harassment, field: :body)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      after.resolve!(by: @moderator, note: "Late report", remove_content: true)
    end
    assert_match "Nothing was removed", error.message
    assert_predicate after.reload, :open?
  end

  test "a pending report whose snapshot carries no text, or other text, is not stamped" do
    third = User.create!(name: "Third", email: "third@example.com").report!(@comment, category: :harassment, field: :body)
    @second.update_column(:snapshot, @second.snapshot.except("content_text"))
    third.update_column(:snapshot, third.snapshot.merge("content_text" => "something else"))
    remove_through(@first)

    [@second, third].each do |report|
      assert_nil report.reload.covered_by_report_id
      error = assert_raises(ActiveRecord::RecordInvalid) { report.resolve!(by: @moderator, note: "x", remove_content: true) }
      assert_match "Nothing was removed", error.message
    end
  end

  test "a report filed after the decision is never stamped, whatever its timestamps say" do
    remove_through(@first)
    late = User.create!(name: "Late", email: "late@example.com").report!(@comment, category: :harassment, field: :body)
    late.update_columns(created_at: 1.year.ago, snapshot: late.snapshot.merge("content_text" => "vile words")) # backdated

    assert_nil late.reload.covered_by_report_id
    error = assert_raises(ActiveRecord::RecordInvalid) { late.resolve!(by: @moderator, note: "Late", remove_content: true) }
    assert_match "Nothing was removed", error.message
  end

  test "an edit between intake and removal: a report on the old text isn't stamped by the removal of the new" do
    @comment.update_column(:body, "new words") # both reports saw "vile words"
    remove_through(@first)

    assert_equal Digest::SHA256.hexdigest("new words"), @first.reload.resolution_actions["removed_text_digest"],
      "the decision records what it actually removed"
    assert_nil @second.reload.covered_by_report_id, "it reported other text than what was removed"
    error = assert_raises(ActiveRecord::RecordInvalid) { @second.resolve!(by: @moderator, note: "x", remove_content: true) }
    assert_match "Nothing was removed", error.message
  end

  test "a removal overturned on appeal covers nothing, though the stamp stays as history" do
    remove_through(@first)
    appeal = Moderate::Appeal.create!(report: @first, appellant: @author, reason: "It was satire", source: "affected_user")
    appeal.uphold!(by: @moderator, note: "Satire; the removal was wrong")

    assert_equal @first.id, @second.reload.covered_by_report_id
    error = assert_raises(ActiveRecord::RecordInvalid) do
      @second.resolve!(by: @moderator, note: "Same content", remove_content: true)
    end
    assert_match "Nothing was removed", error.message
    assert_predicate @second.reload, :open?
  end

  test "a host method that rewrites the field and says it removed it is refused: no stamp, no digest" do
    comment = @first.reportable
    comment.define_singleton_method(:remove_reported_field!) { |_field| update_column(:body, "[edited by moderator]") && true }
    @first.stubs(:reportable).returns(comment)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @first.resolve!(by: @moderator, note: "Harassment", remove_content: true)
    end

    assert_match "Nothing was removed", error.message
    assert_predicate @first.reload, :open?
    assert_nil @first.resolution_actions["removed_text_digest"]
    assert_nil @second.reload.covered_by_report_id, "nobody stamped"
    assert_equal "vile words", @comment.reload.body, "the rewrite rolled back with the refused decision"
  end
end
