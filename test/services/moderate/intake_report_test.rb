# frozen_string_literal: true

require "test_helper"

module Moderate
  module Services
    # Tests for Moderate::Services::IntakeReport — the shared persistence path for an
    # *in-app* community report.
    #
    # WHAT WE'RE PROVING:
    #   1. a successful intake SAVES the report, ACKNOWLEDGES it (DSA Art. 16(4) durable
    #      receipt proof), NOTIFIES the reporter (the `report_received` event), and writes
    #      an AUDIT record — all four side effects, in one call.
    #   2. the receipt notification is GATED on a notifier_email: an in-app reporter who
    #      has a contact email gets a receipt event; the acknowledgement timestamp is set
    #      regardless (the durable legal fact, not the maybe-undelivered email).
    #   3. a validation failure short-circuits: no save, no side effects, `save` is false.
    #
    # We assert side effects against the in-memory ModerateTestRecorder (the dummy app's
    # notify/audit hook doubles) rather than a real mailer/audit store — exactly the seam
    # the gem documents for hosts.
    class IntakeReportTest < ActiveSupport::TestCase
      setup do
        # Re-point the host hooks at the recorder AFTER the suite's `reset!` in setup
        # (which wiped them back to no-ops), and start from an empty recorder so each
        # test's assertions are isolated. See moderate_test_recorder.rb for the WHY.
        Moderate.configure do |config|
          config.audit = ->(event) { ModerateTestRecorder.audit(event) }
          config.notify = ->(event) { ModerateTestRecorder.notify(event) }
        end
        ModerateTestRecorder.clear
      end

      test "saves, acknowledges, notifies the reporter, and audits through the configured seams" do
        reporter = User.create!(name: "Reporter", email: "reporter@example.com")
        reported = User.create!(name: "Reported")

        # The caller builds the (unsaved) Report; the service owns save + side effects.
        report = Moderate::Report.new(category: "harassment", message: "Please review this profile.", good_faith_confirmed: "1")
        intake = Moderate::Services::IntakeReport.new(
          report: report,
          reporter: reporter,
          reportable: reported,
          reported_field: "name"
        )

        assert intake.save
        assert_predicate intake.report.reload, :persisted?

        # DSA Art. 16(4): acknowledgement is the durable, on-record proof of receipt,
        # stamped BEFORE (and independent of) the best-effort email.
        assert_predicate intake.report.acknowledged_at, :present?

        # The reporter has a contact email, so a receipt event was dispatched.
        receipts = ModerateTestRecorder.notifications_named(:report_received)
        assert_equal 1, receipts.size
        assert_equal report, receipts.first.subject
        # The reporter (the actor by default) is resolved into the recipient list so the
        # host's single notify hook can email them.
        assert_includes receipts.first.recipients, reporter
        # Every event carries a redaction-safe one-liner for the admin ping.
        assert_predicate receipts.first.summary, :present?

        # An immutable audit record was written for the intake itself.
        audits = ModerateTestRecorder.audits_named(:report_received)
        assert_equal 1, audits.size
        assert_equal report, audits.first.subject
        assert_equal report.id, audits.first.payload[:report_id]
      end

      test "an in-app reporter without a contact email is acknowledged and audited but gets no receipt email" do
        # No `email` on the reporter, so hydrate_reporter_contact leaves notifier_email
        # blank — the receipt has nowhere to go, but the report is still fully accepted.
        reporter = User.create!(name: "Anon Reporter")
        reported = User.create!(name: "Reported")

        report = Moderate::Report.new(category: "spam", message: "Spammy profile.", good_faith_confirmed: "1")
        intake = Moderate::Services::IntakeReport.new(
          report: report,
          reporter: reporter,
          reportable: reported,
          reported_field: "name"
        )

        assert intake.save
        assert_predicate intake.report.reload.acknowledged_at, :present?

        # No notifier_email ⇒ no receipt event dispatched...
        assert_empty ModerateTestRecorder.notifications_named(:report_received)
        # ...but the intake is STILL audited (the audit is the durable record, not an email).
        assert_equal 1, ModerateTestRecorder.audits_named(:report_received).size
      end

      test "the actor defaults to the reporter and travels on both the receipt and the audit envelope" do
        reporter = User.create!(name: "Reporter", email: "reporter@example.com")
        reported = User.create!(name: "Reported")

        report = Moderate::Report.new(category: "harassment", message: "Look at this.", good_faith_confirmed: "1")
        Moderate::Services::IntakeReport.new(
          report: report, reporter: reporter, reportable: reported, reported_field: "name"
        ).save

        # `actor: :reporter` is the documented default sentinel — the reporter IS the
        # actor for an in-app report, and that identity travels on both events.
        assert_equal reporter, ModerateTestRecorder.notifications_named(:report_received).first.actor
        assert_equal reporter, ModerateTestRecorder.audits_named(:report_received).first.actor
      end

      test "a validation failure short-circuits: no save, no acknowledgement, no side effects" do
        reporter = User.create!(name: "Reporter", email: "reporter@example.com")
        reported = User.create!(name: "Reported")

        # Blank message fails Report's presence validation, so save returns false and the
        # report carries its errors — exactly like a bare model save (controllers rely on this).
        report = Moderate::Report.new(category: "harassment", message: "", good_faith_confirmed: "1")
        intake = Moderate::Services::IntakeReport.new(
          report: report, reporter: reporter, reportable: reported, reported_field: "name"
        )

        refute intake.save
        refute_predicate report, :persisted?
        assert_predicate report.errors[:message], :present?

        # Nothing fired downstream of the failed save.
        assert_empty ModerateTestRecorder.notifications
        assert_empty ModerateTestRecorder.audits
      end
    end
  end
end
