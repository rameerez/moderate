# frozen_string_literal: true

module Moderate
  module Services
    # IntakeAppeal — persistence path for a DSA Article 20 internal complaint
    # ("appeal") against a moderation decision.
    #
    # Art. 20 requires an internal complaint-handling system that is FREE, by
    # ELECTRONIC means, open for AT LEAST SIX MONTHS after the decision, and decided
    # by a human (not solely automated). This service owns only the *intake* half:
    # validating + persisting the complaint and emitting the `appeal_received`
    # receipt. The human decision lives in ResolveAppeal.
    # See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Article 20).
    #
    # The model enforces the legal preconditions (the report must be closed and its
    # appeal window still open) as validations, so a save that violates them returns
    # false with errors — this service doesn't re-implement that, it just runs the
    # surrounding side effects on success.
    #
    # HOST-AGNOSTIC: the appellant may be a User (a logged-in affected party) OR an
    # anonymous notifier (name + email) appealing a public-notice decision. We never
    # assume a User.
    class IntakeAppeal
      # @param appeal [Moderate::Appeal] an unsaved Appeal the caller has populated
      #   (reason, source, appellant contact). The caller owns strong-params; we own
      #   save + side effects.
      # @param report [Moderate::Report] the decision being appealed.
      # @param appellant [user_class, nil] the complainant, when they're a User.
      def initialize(appeal:, report:, appellant: nil)
        @appeal = appeal
        @appeal.assign_attributes(report: report, appellant: appellant)
      end

      attr_reader :appeal

      def save
        return false unless appeal.save

        deliver_receipt
        audit_intake
        true
      end

      private

      # The appellant's receipt ("we got your appeal; a person will review it").
      # Recipient is the User when present, else the lightweight notifier struct,
      # so the host's notify hook addresses both the same way (`recipient.email`).
      def deliver_receipt
        Moderate.notify(
          :appeal_received,
          subject: appeal,
          actor: appeal.appellant,
          recipients: [appellant_recipient].compact,
          payload: {
            report_id: appeal.report_id,
            source: appeal.source,
            summary: "New appeal on Report ##{appeal.report_id}"
          }
        )
      end

      def audit_intake
        Moderate.audit(
          :appeal_received,
          subject: appeal,
          actor: appeal.appellant,
          payload: {
            appeal_id: appeal.id,
            report_id: appeal.report_id,
            source: appeal.source,
            summary: "Appeal ##{appeal.id} filed on Report ##{appeal.report_id}"
          }.compact
        )
      end

      # Prefer the User; fall back to a non-User recipient carrying just the email/
      # name an anonymous appellant supplied. Reuses the same lightweight-recipient
      # contract as IntakeNotice (responds to email/name only) so host mailers don't
      # special-case appeals.
      def appellant_recipient
        return appeal.appellant if appeal.appellant
        return nil if appeal.appellant_email.blank?

        IntakeNotice::NotifierRecipient.new(appeal.appellant_email, appeal.appellant_name)
      end
    end
  end
end
