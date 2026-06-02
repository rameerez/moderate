# frozen_string_literal: true

module Moderate
  module Services
    # IntakeReport — the single persistence path for an *in-app* community report
    # (a logged-in actor tapping "Report" on a piece of content or another user).
    #
    # WHY a service object and not just `Report.create`:
    #   - Intake is more than a save. After the row commits we must (a) acknowledge
    #     receipt, (b) emit the `report_received` event (the reporter's receipt +
    #     the admin ping), and (c) write the immutable audit record. Keeping all of
    #     that in one object means the model stays a plain validating record and the
    #     side effects live in exactly one place — easy to test, impossible to
    #     accidentally skip from a second call site.
    #   - The same shape is reused by the public DSA notice path (see IntakeNotice),
    #     which delegates here once it has assembled a notice-kind Report. One intake,
    #     two front doors.
    #
    # This object is HOST-AGNOSTIC: it never references a concrete content type. The
    # `has_reportable_content` is any `Moderate::Reportable` record (polymorphic), the actor is
    # whatever `Moderate.user_class` resolves to, and notification/audit go through
    # the configured hooks — never a hard-wired mailer.
    class IntakeReport
      # @param report [Moderate::Report] an unsaved Report the caller has already
      #   populated (category, message, etc.). Letting the caller build the record
      #   keeps this service free of the (host-specific) strong-params shape — the
      #   controller/macro decides which attributes are permitted; we own the save +
      #   side effects.
      # @param reporter [user_class, nil] who filed it. nil for an anonymous public
      #   notice (the DSA path), present for an in-app report.
      # @param reportable [Moderate::Reportable, nil] the reported content/record.
      # @param reported_field [String, Symbol, nil] which field was reported.
      # @param actor [user_class, nil] who triggered the intake for the audit/event
      #   envelope (defaults to the reporter — they're the same person for an in-app
      #   report; a public notice may have no actor).
      def initialize(report:, reporter: nil, reportable: nil, reported_field: nil, actor: :reporter)
        @report = report
        @report.assign_attributes(
          reporter: reporter,
          reportable: reportable,
          reported_field: reported_field&.to_s
        )
        # ":reporter" sentinel means "use the reporter as the actor" — the common
        # case — while still letting a caller pass `actor: nil` explicitly.
        @actor = actor == :reporter ? reporter : actor
      end

      attr_reader :report

      # Persist + run side effects. Returns true on success, false if validation
      # failed (the report carries its errors, Rails-conventionally) so a controller
      # can `if intake.save ... else render :new` exactly like a bare model save.
      def save
        return false unless report.save

        # DSA Art. 16(4): the provider must confirm receipt "without undue delay."
        # `acknowledge!` stamps `acknowledged_at` — the durable, on-record proof of
        # receipt — BEFORE we attempt the (best-effort, possibly-undelivered) email,
        # so the legal obligation is met by the database fact, not by a mailer that
        # might not be wired. See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj
        report.acknowledge!

        deliver_receipt
        audit_intake
        true
      end

      private

      attr_reader :actor

      # The reporter's receipt. We only attempt it when there's somewhere to send it
      # (a notifier_email) — an in-app reporter without a contact email simply gets
      # the in-app acknowledgement instead. `Moderate.notify` returns a "delivered"
      # boolean; we don't gate anything on it here (the durable receipt is
      # `acknowledged_at`, set above), but the recipient list is still resolved so
      # the host's single notify hook can email AND ping admins from one event.
      def deliver_receipt
        return if report.skip_received_notice
        return if recipient_email.blank?

        Moderate.notify(
          :report_received,
          subject: report,
          actor: actor,
          recipients: [report.reporter].compact,
          payload: {
            category: report.category,
            intake_kind: report.intake_kind,
            # `:summary` is the contract every event carries — a redaction-safe,
            # ready-to-send one-liner for the admin Telegram ping (docs/notifications.md).
            summary: "New #{report.category} report on #{reportable_label}"
          }
        )
      end

      # Append-only audit of the intake itself (separate from the notify hook, which
      # is for humans). `Moderate.audit` swallows its own errors, so a broken audit
      # sink can never roll back an accepted report.
      def audit_intake
        Moderate.audit(
          :report_received,
          subject: report,
          actor: actor,
          payload: {
            report_id: report.id,
            reportable_type: report.reportable_type,
            reportable_id: report.reportable_id,
            reported_user_id: report.reported_user_id,
            category: report.category,
            intake_kind: report.intake_kind,
            summary: "Report ##{report.id} filed (#{report.category})"
          }.compact
        )
      end

      def recipient_email
        report.notifier_email
      end

      # The reportable's own human label, or a neutral fallback — NEVER a host-
      # specific string. The Reportable concern supplies `moderation_label`.
      def reportable_label
        if report.reportable.respond_to?(:moderation_label)
          report.reportable.moderation_label
        else
          [report.reportable_type, report.reportable_id].compact.join(" #")
        end
      end
    end
  end
end
