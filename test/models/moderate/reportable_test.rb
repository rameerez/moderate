# frozen_string_literal: true

require "test_helper"

module Moderate
  class RemovableComment < ::Comment
    self.table_name = "comments"

    def removable_reported_field?(field)
      field.to_s == "body" && body.present?
    end

    def remove_reported_field!(field)
      return false unless removable_reported_field?(field)

      update!(body: nil)
      true
    end
  end

  class ReportableTest < ActiveSupport::TestCase
    setup do
      @reporter = create_user
      @author = create_user
      @comment = Comment.create!(user: @author, body: "a normal comment")
    end

    test "reports exposes reports filed against the record" do
      refute_predicate @comment, :reported?

      report = Moderate::Report.create!(
        reporter: @reporter,
        reportable: @comment,
        reported_field: "body",
        category: "harassment",
        message: "This should be reviewed.",
        good_faith_confirmed: true
      )

      assert_includes @comment.reports, report
      assert_predicate @comment, :reported?
      assert @comment.reported?(:body)
      refute @comment.reported?(:image)
    end

    test "reported? works on actor reportables and starts false with no rows" do
      refute_predicate @author, :reported?

      report = Moderate::Report.create!(
        reporter: @reporter,
        reportable: @author,
        reported_field: "name",
        category: "impersonation",
        message: "This profile should be reviewed.",
        good_faith_confirmed: true
      )

      assert_includes @author.reports, report
      assert_predicate @author, :reported?
      assert @author.reported?(:name)
      refute @author.reported?(:avatar)
    end

    test "reported? only counts open reports" do
      report = Moderate::Report.create!(
        reporter: @reporter,
        reportable: @comment,
        reported_field: "body",
        category: "harassment",
        message: "This should be reviewed.",
        good_faith_confirmed: true
      )
      report.update!(status: "dismissed", resolution_note: "No violation.")

      refute @comment.reported?
      refute @comment.reported?(:body)
    end

    test "flagged? only counts pending flags on the requested field" do
      refute_predicate @comment, :flagged?

      body_flag = flag_comment!("body")
      flag_comment!("image")

      assert_predicate @comment, :flagged?
      assert @comment.flagged?(:body)
      assert @comment.flagged?("image")
      refute @comment.flagged?(:title)

      body_flag.update!(status: "dismissed", resolution_note: "False positive.")

      refute @comment.flagged?(:body)
      assert @comment.flagged?(:image)
    end

    test "flagged? works on actor reportables and starts false with no rows" do
      refute_predicate @author, :flagged?

      Moderate::Flag.flag!(
        flaggable: @author,
        field: "name",
        owner: @author,
        source: "manual",
        mode: "flag",
        excerpt: "name excerpt",
        categories: [],
        scores: {},
        context: {}
      )

      assert_predicate @author, :flagged?
      assert @author.flagged?(:name)
      refute @author.flagged?(:avatar)
    end

    test "removable_reported_field? defaults false and can be overridden by a reportable" do
      refute @comment.removable_reported_field?(:body)
      refute @comment.remove_reported_field!(:body)

      removable = RemovableComment.create!(user: @author, body: "remove me")

      assert removable.removable_reported_field?(:body)
      assert removable.remove_reported_field!(:body)
      assert_nil removable.reload.body
    end

    test "pending_moderation_flags returns the field-scoped relation" do
      body_flag = flag_comment!("body")
      flag_comment!("image")

      assert_equal [ body_flag ], @comment.pending_moderation_flags(:body).to_a
    end

    private

    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end

    def flag_comment!(field)
      Moderate::Flag.flag!(
        flaggable: @comment,
        field: field,
        owner: @author,
        source: "manual",
        mode: "flag",
        excerpt: "#{field} excerpt",
        categories: [],
        scores: {},
        context: {}
      )
    end
  end
end
