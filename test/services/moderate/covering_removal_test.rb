# frozen_string_literal: true

require "test_helper"

# A second report on content an earlier decision already removed: it closes against
# that decision ("already removed by the decision on Report #X"), the reporter told
# the content is gone, and nothing is removed, announced or stated a second time.
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
end
