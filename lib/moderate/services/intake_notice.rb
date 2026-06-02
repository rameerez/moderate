# frozen_string_literal: true

module Moderate
  module Services
    # IntakeNotice — persistence path for a *public* DSA Article 16 notice.
    #
    # This is the regulator-facing intake: the "Report illegal content (EU)" form
    # you see at the bottom of X / YouTube / Reddit, open to ANYONE (not just
    # logged-in users), by electronic means, with a confirmation of receipt. It is
    # legally distinct from the in-app "Report" button:
    #   - it carries a `legal_reason` from the DSA statement-of-reasons taxonomy
    #     (the law's vocabulary) rather than a community `category` (your rules);
    #   - the notifier may be anonymous (a name+email, not a User);
    #   - it requires the exact electronic location (URL) of the content — Art.16(2)(b);
    #   - it requires a good-faith attestation — Art.16(2)(d).
    # See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Article 16).
    #
    # A notice is NOT a fourth table: it's a `Moderate::Report` with
    # `intake_kind: "dsa"`, so it shares the same queue, evidence snapshot, appeal
    # window, statement-of-reasons path, and Art. 24 transparency counters as an
    # in-app report. One queue, one decision workflow, two front doors. This service
    # builds that notice-kind Report and hands it to IntakeReport for the shared
    # persistence + side effects, then emits the notice-specific `notice_received`
    # event whose delivery boolean gates the Art. 16(4) "confirmation of receipt".
    #
    # HOST-AGNOSTIC: no concrete content type is named. The URL is resolved to a
    # reportable record (if the host can) by the Report model's snapshot logic; this
    # service only owns intake orchestration and the legal-email gating.
    class IntakeNotice
      # @param attributes [Hash] the public-form attributes, already strong-param'd
      #   by the controller: notifier_name, notifier_email, good_faith_confirmed,
      #   legal_reason, legal_country_code, subject_url(s), content_type, message
      #   (the substantiated explanation), anonymous, reported_account_identifier.
      # @param reporter [user_class, nil] the submitter IF they happened to be
      #   logged in (the form is public, so usually nil).
      def initialize(attributes:, reporter: nil)
        # Force the DSA shape regardless of what the form posted: a public notice is
        # always intake_kind "dsa". We default the community `category` to a neutral
        # "illegal_content" because the column is NOT NULL and a notice's real
        # taxonomy lives in `legal_reason` — the category is just the bucket that
        # keeps a notice in the same queue as community reports.
        @report = Moderate::Report.new(attributes)
        @report.assign_attributes(
          intake_kind: "dsa",
          category: @report.category.presence || "illegal_content"
        )
        @reporter = reporter
      end

      attr_reader :report

      def save
        # Reuse the shared intake (save + acknowledge! + audit). We pass the report
        # straight through — it already carries the notice attributes and the forced
        # DSA shape. The reporter is the actor when present (a logged-in submitter);
        # for a truly anonymous notice the actor is nil, which the event envelope
        # handles (system/no-actor events are normal).
        intake = IntakeReport.new(
          report: report,
          reporter: reporter,
          reportable: report.reportable,
          reported_field: report.reported_field,
          actor: reporter
        )
        return false unless intake.save

        deliver_confirmation_of_receipt
        true
      end

      private

      attr_reader :reporter

      # DSA Art. 16(4): "the provider shall, without undue delay, send to that
      # individual or entity a confirmation of receipt of the notice."
      #
      # We send it to the NOTIFIER (who is often not a User — an anonymous person
      # with just an email), distinct from IntakeReport's in-app receipt. The notify
      # hook returns a "delivered" boolean: when it's truthy we stamp
      # `decision_notified_at`... no — we stamp nothing here, because the durable
      # legal proof of *receipt* is `acknowledged_at` (already set by IntakeReport).
      # The boolean instead lets the controller fall back to an on-screen receipt
      # (the form shows a reference number) when the host hasn't wired a mailer —
      # that's the whole reason `Moderate.notify` returns delivered/undelivered
      # rather than nothing. See docs/notifications.md and docs/dsa-notice-form.md.
      #
      # The recipient is a lightweight notifier struct (responds to email/name) when
      # the submitter isn't a User, so the host's `notify` hook can email it the same
      # way it emails a real user — the recipes guard with `respond_to?(:email)`.
      def deliver_confirmation_of_receipt
        return false if report.notifier_email.blank?

        Moderate.notify(
          :notice_received,
          subject: report,
          actor: reporter,
          recipients: [notifier_recipient],
          payload: {
            legal_reason: report.legal_reason,
            legal_country_code: report.legal_country_code,
            subject_url: report.subject_url,
            # Redaction-safe admin one-liner. We deliberately keep host content out
            # of it — just the legal ground and an opaque pointer to the record.
            summary: "New DSA notice (#{report.legal_reason || 'illegal_content'}) — Report ##{report.id}"
          }
        )
      end

      # A non-User recipient the host's mailer can address. We prefer the real
      # reporter (a User) when the submitter was logged in; otherwise we build a
      # minimal value object that quacks like a recipient (responds to `email`,
      # `name`) — documented in docs/notifications.md as the "lightweight recipient"
      # for anonymous DSA notifiers.
      def notifier_recipient
        return report.reporter if report.reporter

        NotifierRecipient.new(report.notifier_email, report.notifier_name)
      end

      # The anonymous-notifier recipient. Intentionally tiny and NOT a User: the
      # host's notify hook reaches `recipient.email` / `recipient.name` and nothing
      # else. Frozen value object.
      NotifierRecipient = Data.define(:email, :name) do
        # Mirror the User-ish reader some host mailers reach for, so a notifier and a
        # User are interchangeable at the `recipient.email` call site.
        def display_name = name.to_s.empty? ? email : name
      end
    end
  end
end
