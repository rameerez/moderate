# frozen_string_literal: true

require "test_helper"

module Moderate
  class ReportableTest < ActiveSupport::TestCase
    setup do
      @reporter = create_user
      @author = create_user
      @comment = Comment.create!(user: @author, body: "a normal comment")
    end

    test "reports exposes reports filed against the record" do
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
