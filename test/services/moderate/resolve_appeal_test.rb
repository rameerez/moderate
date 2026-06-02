# frozen_string_literal: true

require "test_helper"

module Moderate
  module Services
    # Tests for Moderate::Services::ResolveAppeal — the HUMAN decision on a DSA Art. 20
    # appeal (uphold! overturns the original decision, reject! confirms it).
    #
    # Art. 20 forbids deciding appeals "solely on the basis of automated means," which is
    # why there is no auto-decide path: both transitions REQUIRE a `by:` moderator and a
    # `note:`. What we prove (host-agnostic):
    #   - uphold!/reject! atomically close the appeal, stamp the human decider, and audit;
    #   - a NOTE IS MANDATORY;
    #   - the appellant is NOTIFIED of the outcome (the `appeal_decision` event), and
    #     `decision_notified_at` is stamped only when the hook reports delivery;
    #   - the DOUBLE-DECIDE guard: a decided appeal is immutable (hard RecordInvalid on a
    #     second decision, unlike a flag's benign re-review).
    class ResolveAppealTest < ActiveSupport::TestCase
      setup do
        Moderate.configure do |config|
          config.audit = ->(event) { ModerateTestRecorder.audit(event) }
          config.notify = ->(event) { ModerateTestRecorder.notify(event) }
        end
        ModerateTestRecorder.clear
      end

      test "upholding closes the appeal, stamps the human decider, audits, and notifies" do
        moderator = User.create!(name: "Mod")
        appeal = create_appeal

        Moderate::Services::ResolveAppeal.new(appeal, by: moderator).uphold!(note: "We reversed the decision.")

        appeal.reload
        assert_equal "upheld", appeal.status
        # The human decider is part of the permanent record (Art. 20: not solely automated).
        assert_equal moderator, appeal.resolved_by
        assert_predicate appeal.resolved_at, :present?
        # Delivered ⇒ the legal-communication timestamp is stamped.
        assert_predicate appeal.decision_notified_at, :present?

        audits = ModerateTestRecorder.audits_named(:appeal_decision)
        assert_equal 1, audits.size
        assert_equal "upheld", audits.first.payload[:status]

        decisions = ModerateTestRecorder.notifications_named(:appeal_decision)
        assert_equal 1, decisions.size
        assert_equal "upheld", decisions.first.payload[:status]
      end

      test "rejecting confirms the original decision and notifies the appellant" do
        moderator = User.create!(name: "Mod")
        appeal = create_appeal

        Moderate::Services::ResolveAppeal.new(appeal, by: moderator).reject!(note: "Original decision stands.")

        assert_equal "rejected", appeal.reload.status
        assert_equal "rejected", ModerateTestRecorder.notifications_named(:appeal_decision).first.payload[:status]
      end

      test "an appeal cannot be decided without a note" do
        moderator = User.create!(name: "Mod")
        appeal = create_appeal

        error = assert_raises(ActiveRecord::RecordInvalid) do
          Moderate::Services::ResolveAppeal.new(appeal, by: moderator).reject!(note: " ")
        end
        assert_predicate error.record.errors[:resolution_note], :present?

        assert_equal "open", appeal.reload.status
        assert_empty ModerateTestRecorder.notifications_named(:appeal_decision)
        assert_empty ModerateTestRecorder.audits_named(:appeal_decision)
      end

      test "a decided appeal cannot be decided a second time (immutable, idempotent under lock)" do
        moderator = User.create!(name: "Mod")
        appeal = create_appeal

        Moderate::Services::ResolveAppeal.new(appeal, by: moderator).uphold!(note: "First decision.")
        ModerateTestRecorder.clear

        # The in-lock `open?` re-check makes a concurrent/second decision bail cleanly.
        assert_raises(ActiveRecord::RecordInvalid) do
          Moderate::Services::ResolveAppeal.new(appeal, by: moderator).reject!(note: "Second decision.")
        end

        appeal.reload
        assert_equal "upheld", appeal.status
        assert_equal "First decision.", appeal.resolution_note
        assert_empty ModerateTestRecorder.audits_named(:appeal_decision)
      end

      private

      # An open appeal filed against a resolved, still-appealable report.
      def create_appeal
        report = Moderate::Report.create!(
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

        Moderate::Appeal.create!(
          report: report,
          appellant_name: "Appealing Person",
          appellant_email: "appeal@example.com",
          reason: "Please review this decision."
        )
      end
    end
  end
end
