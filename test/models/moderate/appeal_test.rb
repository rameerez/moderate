# frozen_string_literal: true

require "test_helper"

module Moderate
  # Tests for Moderate::Appeal — the DSA Art. 20 internal complaint against a
  # decision: free, electronic, open for at least six months, decided by a human.
  #
  # Ported from test/models/moderation/appeal_test.rb and de-host-ified — the
  # reference's external-URL notice is replaced by a community report against the
  # dummy Comment, and the six-month-window assertions track the gem's
  # `appeal_deadline_at` / `resolved_at` columns exactly.
  class AppealTest < ActiveSupport::TestCase
    setup do
      @reporter = create_user
      @author = create_user
      @comment = Comment.create!(user: @author, body: "a perfectly fine comment")
    end

    test "an appeal on a closed report inside the redress window is valid" do
      appeal = Moderate::Appeal.new(
        report: closed_report,
        appellant_name: "Appealing User",
        appellant_email: "appeal@example.com",
        reason: "Please review this decision."
      )

      assert_predicate appeal, :valid?
    end

    test "an appeal against a still-open report is rejected (you appeal a DECISION)" do
      open_report = build_report.tap(&:save!)

      appeal = Moderate::Appeal.new(
        report: open_report,
        appellant_name: "Appealing User",
        appellant_email: "appeal@example.com",
        reason: "Please review this decision."
      )

      refute appeal.valid?
      assert appeal.errors[:report].any?
    end

    test "an appeal filed after the six-month window has closed is rejected" do
      appeal = Moderate::Appeal.new(
        report: closed_report(appeal_deadline_at: 1.day.ago),
        appellant_name: "Appealing User",
        appellant_email: "appeal@example.com",
        reason: "Please review this decision."
      )

      refute appeal.valid?
      assert appeal.errors[:report].any?
    end

    test "an appellant email is mandatory (the decision must be deliverable)" do
      appeal = Moderate::Appeal.new(
        report: closed_report,
        appellant_name: "Appealing User",
        reason: "Please review this decision."
      )

      refute appeal.valid?
      assert appeal.errors[:appellant_email].any?
    end

    test "source is constrained to the allowed vocabulary and defaults to notifier" do
      appeal = Moderate::Appeal.new(
        report: closed_report, appellant_email: "appeal@example.com",
        reason: "x", source: "bogus"
      )
      refute appeal.valid?
      assert appeal.errors[:source].any?

      default = Moderate::Appeal.new(report: closed_report, appellant_email: "a@example.com", reason: "x")
      default.valid?
      # normalize_strings defaults a blank source to "notifier".
      assert_equal "notifier", default.source
    end

    test "status is constrained to the allowed vocabulary (in the model, not the DB)" do
      # `status` is validated by an ActiveModel inclusion validation, not a DB check
      # constraint, so an unknown value surfaces a friendly model error.
      appeal = Moderate::Appeal.new(
        report: closed_report, appellant_email: "appeal@example.com",
        reason: "x", status: "withdrawn"
      )
      refute appeal.valid?
      assert appeal.errors[:status].any?
    end

    test "a logged-in appellant's contact is hydrated onto the appeal" do
      user = create_user
      appeal = Moderate::Appeal.new(
        report: closed_report,
        appellant: user,
        reason: "Please review this decision."
      )

      assert_predicate appeal, :valid?
      # hydrate_appellant_contact copies the user's email (read via try) onto the row.
      assert_equal user.email, appeal.appellant_email
    end

    test "the decision snapshot is captured at create time" do
      report = closed_report
      appeal = Moderate::Appeal.create!(
        report: report,
        appellant_email: "appeal@example.com",
        reason: "Please review this decision."
      )

      # The snapshot anchors the complaint to exactly what was decided.
      assert_equal report.id, appeal.snapshot["report_id"]
      assert_equal report.status, appeal.snapshot["report_status"]
      assert appeal.snapshot["captured_at"].present?
    end

    private

    # A valid, persistable OPEN community report against the dummy comment.
    def build_report
      Moderate::Report.new(
        reporter: @reporter,
        reportable: @comment,
        reported_field: "body",
        category: "harassment",
        message: "Please review",
        good_faith_confirmed: true
      )
    end

    # A report that has been DECIDED (resolved_at + a resolution note/basis) with the
    # six-month redress window open. The Appeal model keys "is it closed?" off
    # resolved_at and "is it still appealable?" off appeal_deadline_at.
    def closed_report(appeal_deadline_at: 1.month.from_now)
      build_report.tap do |report|
        report.status = "dismissed"
        report.resolution_note = "No violation found"
        report.resolution_basis = "no_violation"
        report.resolved_at = Time.current
        report.appeal_deadline_at = appeal_deadline_at
        report.save!
      end
    end

    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end
  end
end
