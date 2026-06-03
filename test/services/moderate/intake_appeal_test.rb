# frozen_string_literal: true

require "test_helper"

module Moderate
  module Services
    # Tests for Moderate::Services::IntakeAppeal — the persistence path for a DSA Art. 20
    # internal complaint ("appeal") against a moderation decision.
    #
    # What we prove (host-agnostic):
    #   - a successful intake SAVES the appeal, NOTIFIES the appellant (the `appeal_received`
    #     receipt), and AUDITS the intake;
    #   - the appeal `source` (notifier / affected_user / ...) is preserved for the Art. 24
    #     transparency counters;
    #   - the model's legal preconditions (report must be closed AND still within the
    #     6-month window) gate the save — a violation returns false with errors, and the
    #     service runs no side effects.
    class IntakeAppealTest < ActiveSupport::TestCase
      setup do
        Moderate.configure do |config|
          config.audit = ->(event) { ModerateTestRecorder.audit(event) }
          config.notify = ->(event) { ModerateTestRecorder.notify(event) }
        end
        ModerateTestRecorder.clear
      end

      test "saves, notifies the appellant receipt, and audits the intake" do
        report = closed_report
        appeal = Moderate::Appeal.new(
          appellant_name: "Appealing Person",
          appellant_email: "appeal@example.com",
          reason: "Please review this decision."
        )
        intake = Moderate::Services::IntakeAppeal.new(appeal: appeal, report: report, appellant: nil)

        assert intake.save
        assert_predicate intake.appeal.reload, :persisted?
        assert_equal report, intake.appeal.report

        receipts = ModerateTestRecorder.notifications_named(:appeal_received)
        assert_equal 1, receipts.size
        assert_equal appeal, receipts.first.subject
        # The anonymous appellant is addressed via a lightweight notifier recipient that
        # quacks like a user (responds to email/name), so the host mailer needn't special-case.
        recipient = receipts.first.recipients.first
        assert_equal "appeal@example.com", recipient.email

        audits = ModerateTestRecorder.audits_named(:appeal_received)
        assert_equal 1, audits.size
        assert_equal appeal.id, audits.first.payload[:appeal_id]
        assert_equal report.id, audits.first.payload[:report_id]
      end

      test "preserves the affected-user appeal source for transparency counters" do
        report = closed_report
        appeal = Moderate::Appeal.new(
          appellant_name: "Affected Person",
          appellant_email: "affected@example.com",
          source: "affected_user",
          reason: "Please review this restriction."
        )

        assert Moderate::Services::IntakeAppeal.new(appeal: appeal, report: report, appellant: nil).save

        assert_equal "affected_user", appeal.reload.source
        assert_equal "affected_user", ModerateTestRecorder.audits_named(:appeal_received).first.payload[:source]
      end

      test "routes the receipt to the logged-in appellant when present" do
        report = closed_report
        appellant = User.create!(name: "User Appellant", email: "user-appellant@example.com")
        appeal = Moderate::Appeal.new(reason: "Please review.", source: "affected_user")

        assert Moderate::Services::IntakeAppeal.new(appeal: appeal, report: report, appellant: appellant).save

        # When the appellant is a real User, THEY are the recipient (not a notifier struct).
        assert_includes ModerateTestRecorder.notifications_named(:appeal_received).first.recipients, appellant
      end

      test "a save blocked by the model's legal preconditions runs no side effects" do
        # An appeal against an UNRESOLVED report violates `report_must_be_closed`, so the
        # save fails and the service short-circuits with no notify/audit.
        open_report = Moderate::Report.create!(
          notifier_name: "Notifier", notifier_email: "notifier@example.com",
          category: "illegal_content", subject_url: "https://example.test/x",
          message: "Please review", good_faith_confirmed: true
        )
        appeal = Moderate::Appeal.new(appellant_email: "appeal@example.com", reason: "Too early.")
        intake = Moderate::Services::IntakeAppeal.new(appeal: appeal, report: open_report, appellant: nil)

        refute intake.save
        refute_predicate appeal, :persisted?
        assert_predicate appeal.errors[:report], :present?
        assert_empty ModerateTestRecorder.notifications
        assert_empty ModerateTestRecorder.audits
      end

      private

      # A resolved report with an open appeal window — the only thing an appeal can attach to.
      def closed_report
        Moderate::Report.create!(
          notifier_name: "Notice Sender",
          notifier_email: "notice@example.com",
          category: "illegal_content",
          subject_url: "https://example.test/content/1",
          message: "Please review",
          good_faith_confirmed: true,
          status: "dismissed",
          resolution_note: "No violation",
          resolution_basis: "no_violation",
          decision_visibility: "no_restriction",
          resolved_at: Time.current,
          appeal_deadline_at: 1.month.from_now
        )
      end
    end
  end
end
