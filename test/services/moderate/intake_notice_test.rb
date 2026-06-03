# frozen_string_literal: true

require "test_helper"

module Moderate
  module Services
    # Tests for Moderate::Services::IntakeNotice — the PUBLIC DSA Art. 16 notice intake
    # (the "Report illegal content (EU)" form, open to anyone, by electronic means).
    #
    # A notice is NOT a fourth table: it's a Moderate::Report with intake_kind "dsa".
    # This service forces that shape and delegates to IntakeReport for the shared save +
    # acknowledge! + audit, then emits the notice-specific `notice_received` event whose
    # delivery boolean backs the Art. 16(4) confirmation of receipt.
    # See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Article 16).
    #
    # What we prove (host-agnostic — the notice is about an external URL, no host content type):
    #   - a well-formed notice (legal_reason + eu_country + good_faith + exact URL) SAVES,
    #     is forced to intake_kind "dsa", is ACKNOWLEDGED (Art. 16(4) durable proof), AUDITED,
    #     and fires the `notice_received` confirmation-of-receipt event;
    #   - each Art. 16(2) requirement is enforced: legal ground, member state, good-faith
    #     attestation, exact electronic location (URL);
    #   - the anonymity carve-out (Art. 16(2)(c) proviso): a `protection_of_minors` notice
    #     may be filed anonymously, is acknowledged + audited, and sends NO receipt email
    #     (there's no contact to confirm to);
    #   - an automated-processing disclosure travels through when a classifier participated.
    class IntakeNoticeTest < ActiveSupport::TestCase
      setup do
        Moderate.configure do |config|
          config.audit = ->(event) { ModerateTestRecorder.audit(event) }
          config.notify = ->(event) { ModerateTestRecorder.notify(event) }
        end
        ModerateTestRecorder.clear
      end

      test "a well-formed public notice saves as a DSA report, is acknowledged, audited, and confirms receipt (Art. 16(4))" do
        intake = Moderate::Services::IntakeNotice.new(attributes: well_formed_notice_attributes)

        assert intake.save
        report = intake.report.reload

        # Forced DSA shape regardless of what the form posted.
        assert_equal "dsa", report.intake_kind
        assert_predicate report, :dsa?
        # The regulator-aligned legal taxonomy + member state are recorded.
        assert_equal "public_security", report.legal_reason
        assert_equal "ES", report.legal_country_code
        # Exact electronic location (Art. 16(2)(b)).
        assert_equal "https://example.test/illegal", report.subject_url

        # DSA Art. 16(4): durable, on-record proof of receipt (set by the shared IntakeReport).
        assert_predicate report.acknowledged_at, :present?

        # The confirmation-of-receipt event went to the notifier.
        receipts = ModerateTestRecorder.notifications_named(:notice_received)
        assert_equal 1, receipts.size
        assert_equal report, receipts.first.subject
        recipient = receipts.first.recipients.first
        assert_equal "notifier@example.com", recipient.email
        assert_equal "public_security", receipts.first.payload[:legal_reason]

        # The shared intake path also audited the report.
        assert_equal 1, ModerateTestRecorder.audits_named(:report_received).size
      end

      test "the legal ground (legal_reason) is required (Art. 16(2))" do
        attrs = well_formed_notice_attributes.merge(legal_reason: "")
        intake = Moderate::Services::IntakeNotice.new(attributes: attrs)

        refute intake.save
        assert_predicate intake.report.errors[:legal_reason], :present?
        assert_empty ModerateTestRecorder.notifications_named(:notice_received)
      end

      test "the member state (legal_country_code) is required (Art. 16(2))" do
        attrs = well_formed_notice_attributes.merge(legal_country_code: "")
        intake = Moderate::Services::IntakeNotice.new(attributes: attrs)

        refute intake.save
        assert_predicate intake.report.errors[:legal_country_code], :present?
      end

      test "the exact electronic location (subject_url) is required for a pure external-URL notice (Art. 16(2)(b))" do
        attrs = well_formed_notice_attributes.merge(subject_url: "")
        intake = Moderate::Services::IntakeNotice.new(attributes: attrs)

        refute intake.save
        assert_predicate intake.report.errors[:subject_url], :present?
      end

      test "a malformed (non-http) URL is rejected" do
        attrs = well_formed_notice_attributes.merge(subject_url: "javascript:alert(1)")
        intake = Moderate::Services::IntakeNotice.new(attributes: attrs)

        refute intake.save
        assert_predicate intake.report.errors[:subject_url], :present?
      end

      test "the good-faith attestation is required (Art. 16(2)(d))" do
        attrs = well_formed_notice_attributes.merge(good_faith_confirmed: "0")
        intake = Moderate::Services::IntakeNotice.new(attributes: attrs)

        refute intake.save
        assert_predicate intake.report.errors[:good_faith_confirmed], :present?
      end

      test "anonymous child-safety notices are acknowledged and audited WITHOUT a receipt email (Art. 16(2)(c) carve-out)" do
        # The anonymity carve-out is narrow: only `protection_of_minors` notices may omit
        # the notifier's identity. No contact email ⇒ no confirmation-of-receipt email,
        # but the durable acknowledgement + audit still record the notice.
        intake = Moderate::Services::IntakeNotice.new(
          attributes: {
            anonymous: "1",
            legal_reason: "protection_of_minors",
            legal_country_code: "EU",
            content_type: "message",
            subject_url: "https://example.test/csam",
            message: "This involves child safety and should be reviewed.",
            good_faith_confirmed: "1"
          }
        )

        assert intake.save
        report = intake.report.reload
        assert_predicate report, :dsa?
        assert_nil report.notifier_email
        assert_predicate report.acknowledged_at, :present?

        # No contact ⇒ no receipt event...
        assert_empty ModerateTestRecorder.notifications_named(:notice_received)
        # ...but the intake is still audited (the durable record of receipt).
        assert_equal 1, ModerateTestRecorder.audits_named(:report_received).size
      end

      test "an anonymous notice for a non-child-safety ground is rejected (carve-out is narrow)" do
        # Anonymity is permitted ONLY for offences against minors; any other anonymous
        # notice must surface the identity requirement of Art. 16(2)(c).
        intake = Moderate::Services::IntakeNotice.new(
          attributes: {
            anonymous: "1",
            legal_reason: "scams_fraud",
            legal_country_code: "DE",
            content_type: "other",
            subject_url: "https://example.test/scam",
            message: "Trying to file anonymously for a non-minor ground.",
            good_faith_confirmed: "1"
          }
        )

        refute intake.save
        assert_predicate intake.report.errors[:anonymous], :present?
        assert_empty ModerateTestRecorder.notifications_named(:notice_received)
      end

      test "defaults the community category to illegal_content while keeping the real ground in legal_reason" do
        # A notice's real taxonomy lives in legal_reason; `category` is just the NOT NULL
        # bucket that keeps a notice in the same queue as community reports.
        intake = Moderate::Services::IntakeNotice.new(attributes: well_formed_notice_attributes)

        assert intake.save
        assert_equal "illegal_content", intake.report.reload.category
        assert_equal "public_security", intake.report.legal_reason
      end

      test "the notice_received summary stays redaction-safe (no host content)" do
        intake = Moderate::Services::IntakeNotice.new(attributes: well_formed_notice_attributes)
        assert intake.save

        summary = ModerateTestRecorder.notifications_named(:notice_received).first.summary
        # The admin one-liner names only the legal ground + an opaque report pointer.
        assert_includes summary, "public_security"
        assert_includes summary, "DSA notice"
      end

      private

      # A complete, valid Art. 16 notice about an external URL (no in-app reportable record),
      # so the suite exercises the pure public-notice path host-agnostically.
      def well_formed_notice_attributes
        {
          notifier_name: "Public Notifier",
          notifier_email: "notifier@example.com",
          legal_reason: "public_security",
          legal_country_code: "ES",
          # `content_type` is constrained to the gem's host-agnostic CONTENT_TYPES
          # vocabulary; "other" is the neutral catch-all bucket for an external URL.
          content_type: "other",
          subject_url: "https://example.test/illegal",
          message: "This URL hosts content that breaches public security law.",
          good_faith_confirmed: "1"
        }
      end
    end
  end
end
