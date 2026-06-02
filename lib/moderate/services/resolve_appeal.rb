# frozen_string_literal: true

module Moderate
  module Services
    # ResolveAppeal — the human decision on a DSA Article 20 appeal, behind
    # `appeal.uphold!` / `appeal.reject!`.
    #
    # Art. 20 demands appeals be decided "in a timely, non-discriminatory, diligent
    # and non-arbitrary manner" and crucially "NOT SOLELY ON THE BASIS OF AUTOMATED
    # MEANS." That last clause is why there is no auto-decide path here at all:
    # `uphold!`/`reject!` REQUIRE a `by:` moderator and a `note:` — a human and a
    # reason — and the model column for the moderator (`resolved_by`) makes the human
    # decider part of the permanent record.
    # See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Article 20).
    #
    # Same atomic discipline as ResolveReport: the transition runs under a row lock,
    # re-checks `open?` inside the lock (so two moderators can't both decide the same
    # appeal), and the notification happens after the lock releases.
    #
    # NOTE on enforcement: upholding an appeal means the ORIGINAL decision was wrong
    # and should be reversed (Art. 20 outcomes must be acted on). Reversal is
    # host-specific — re-publishing content, lifting a ban — and the gem can't know
    # how to undo an arbitrary host action. So this service records the upheld
    # outcome and emits `appeal_decision`; the host wires the actual reversal off
    # that event (or off its `audit` hook). We document this rather than pretend a
    # generic "un-remove" exists.
    class ResolveAppeal
      def initialize(appeal, by:)
        @appeal = appeal
        @moderator = by
      end

      def uphold!(note:)
        transition!("upheld", note)
      end

      def reject!(note:)
        transition!("rejected", note)
      end

      private

      attr_reader :appeal, :moderator

      def transition!(status, note)
        note = require_note!(note)

        appeal.with_lock do
          appeal.reload

          # A decided appeal is immutable — re-check inside the lock so a concurrent
          # second decision bails cleanly instead of overwriting the first.
          unless appeal.open?
            appeal.errors.add(:base, already_closed_message)
            raise ActiveRecord::RecordInvalid, appeal
          end

          appeal.update!(
            status: status,
            resolution_note: note,
            resolved_by: moderator,
            resolved_at: Time.now
          )

          audit_decision(status, note)
        end

        deliver_decision_notice(status)
        appeal
      end

      # Inform the complainant of the appeal outcome and remaining redress (out-of-
      # court dispute settlement / judicial — copy is the host's, it names the
      # jurisdiction). We stamp `decision_notified_at` only when the hook reported a
      # delivery, so the timestamp reflects an actual communication.
      def deliver_decision_notice(status)
        delivered = Moderate.notify(
          :appeal_decision,
          subject: appeal,
          actor: moderator,
          recipients: [appellant_recipient].compact,
          payload: {
            appeal_id: appeal.id,
            report_id: appeal.report_id,
            status: status,
            reason: appeal.resolution_note,
            summary: "Decision on appeal for Report ##{appeal.report_id}: #{status}"
          }.compact
        )

        appeal.update_column(:decision_notified_at, Time.now) if delivered
      end

      def audit_decision(status, note)
        Moderate.audit(
          :appeal_decision,
          subject: appeal,
          actor: moderator,
          payload: {
            appeal_id: appeal.id,
            report_id: appeal.report_id,
            status: status,
            note: note,
            summary: "Appeal ##{appeal.id} #{status} by moderator"
          }.compact
        )
      end

      # The complainant: a User when present, else the lightweight notifier struct.
      def appellant_recipient
        return appeal.appellant if appeal.appellant
        return nil if appeal.appellant_email.blank?

        IntakeNotice::NotifierRecipient.new(appeal.appellant_email, appeal.appellant_name)
      end

      def require_note!(note)
        normalized = note.to_s.strip
        return normalized unless normalized.empty?

        appeal.errors.add(:resolution_note, :blank)
        raise ActiveRecord::RecordInvalid, appeal
      end

      def already_closed_message
        if defined?(I18n)
          I18n.t("moderate.errors.appeal_already_closed", default: "This appeal has already been decided.")
        else
          "This appeal has already been decided."
        end
      end
    end
  end
end
