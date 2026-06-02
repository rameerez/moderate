# frozen_string_literal: true

module Moderate
  module Services
    # ResolveReport — the audited decision engine behind `report.resolve!` /
    # `report.dismiss!`.
    #
    # This is where a moderator's decision actually happens, and it's the most
    # legally-loaded path in the gem, so it's built defensively:
    #
    #   1. ATOMIC + IDEMPOTENT. The whole transition runs inside `report.with_lock`
    #      (a SELECT ... FOR UPDATE row lock). Two moderators clicking "resolve" at
    #      once must not both run enforcement (double-ban, double-remove) — the lock
    #      serializes them, and we RE-CHECK `open?` *inside* the lock after reload so
    #      the second one sees the closed record and bails with a clean error rather
    #      than re-applying actions.
    #
    #   2. A NOTE IS MANDATORY. DSA Art. 17 requires a "clear and specific statement
    #      of reasons"; the moderator's note is the human-readable ground. No note,
    #      no decision — we raise RecordInvalid with the note error attached.
    #      See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Article 17).
    #
    #   3. ENFORCEMENT IS HOST-AGNOSTIC. Content removal calls the reportable's own
    #      `remove_reported_field!` (the host decides what "remove" means for its
    #      content); a ban calls `Moderate.apply_ban` → the host's `ban_handler`
    #      (the host decides what "banned" means). The gem never reaches into a
    #      host's domain — it only invokes the contracts.
    #
    #   4. TWO DECISION EVENTS, ON PURPOSE. `report_decision` tells the *reporter*
    #      "we handled it" (Art. 16(5)); `affected_user_decision` gives the *content
    #      owner* the Art. 17 statement of reasons (action taken, ground, automated-
    #      means disclosure, appeal path). Different people, different rights — see
    #      docs/notifications.md ("Why two decision events").
    class ResolveReport
      def initialize(report, by:)
        @report = report
        @moderator = by
      end

      # Resolve WITH action (the report was valid; we acted on the content/account).
      # `resolution_basis` records the legal/contractual ground bucket; it's
      # validated against the migration's check-constraint list by the model.
      def resolve!(note:, remove_content: false, ban_user: false, resolution_basis: "terms")
        note = require_note!(note)
        actions = {
          remove_content: truthy?(remove_content),
          ban_user: truthy?(ban_user),
          resolution_basis: resolution_basis.to_s.strip.presence || "terms"
        }

        transition!("actioned", note: note, actions: actions) do
          remove_reported_content! if actions[:remove_content]
          ban_reported_user!(note: note) if actions[:ban_user]
        end
      end

      # Dismiss (no violation found). Still requires a note (Art. 17 applies to the
      # reporter's right to know the outcome too) and still opens an appeal window —
      # the *reporter* can appeal a dismissal.
      def dismiss!(note:)
        note = require_note!(note)
        transition!("dismissed", note: note, actions: { resolution_basis: "no_violation" })
      end

      private

      attr_reader :report, :moderator

      # The atomic core. Everything that mutates state happens under the row lock;
      # the (slow, fallible) notifications happen AFTER the lock is released, so a
      # broken mailer can't hold a database lock or roll back the decision.
      def transition!(status, note:, actions:)
        report.with_lock do
          report.reload

          # Re-check inside the lock — see class doc point (1). A closed report is a
          # no-op error, never a silent re-apply of enforcement.
          unless report.open?
            report.errors.add(:base, already_closed_message)
            raise ActiveRecord::RecordInvalid, report
          end

          # Enforcement runs INSIDE the transaction so that if removal/ban raises,
          # the whole decision rolls back — we never record "actioned" while the
          # content is still up.
          yield if block_given?

          report.update!(
            status: status,
            resolution_note: note,
            resolution_actions: actions.transform_keys(&:to_s),
            resolution_basis: actions.fetch(:resolution_basis, "no_violation"),
            decision_visibility: decision_visibility_for(status, actions),
            # Stamp the appeal window NOW (Art. 20: open ≥ 6 months from the
            # decision). The model owns APPEAL_WINDOW so the duration is configured
            # in one place.
            appeal_deadline_at: Time.now + Moderate::Report::APPEAL_WINDOW,
            resolved_by: moderator,
            resolved_at: Time.now
          )

          audit_decision(status, actions, note)
        end

        deliver_decision_notices
        report
      end

      # --- Enforcement (host contracts only) ----------------------------------

      def remove_reported_content!
        return if report.reportable.blank?
        return unless report.reportable.respond_to?(:remove_reported_field!)

        report.reportable.remove_reported_field!(report.reported_field)
      end

      def ban_reported_user!(note:)
        user = report.reported_user
        return if user.blank?

        # The gem never bans directly — it asks the host's ban_handler what "banned"
        # means (suspend, soft-delete, flip a flag…). No-op by default, so the
        # decision still completes and audits even if no ban is wired.
        Moderate.apply_ban(user: user, by: moderator, reason: note)
      end

      # --- Notifications (after the lock) -------------------------------------

      def deliver_decision_notices
        notify_reporter
        notify_affected_user
      end

      # report_decision → the reporter (Art. 16(5): inform the notice provider of the
      # decision + redress). We stamp `decision_notified_at` ONLY when the hook
      # reported a delivery — that timestamp is the record that the legal
      # communication actually went out, so it must reflect reality, not intent.
      # `Moderate.notify` returns the delivered boolean precisely for this gate.
      def notify_reporter
        return if report.notifier_email.blank?

        delivered = Moderate.notify(
          :report_decision,
          subject: report,
          actor: moderator,
          recipients: [report.reporter].compact,
          payload: decision_payload.merge(
            summary: "Decision on Report ##{report.id}: #{report.status}"
          )
        )

        report.update_column(:decision_notified_at, Time.now) if delivered
      end

      # affected_user_decision → the content owner: the DSA Art. 17 statement of
      # reasons. Only fires when we actually restricted something (an "actioned"
      # decision) and there's an identifiable owner to tell. Carries the action, the
      # ground, the automated-means disclosure, and the appeal entry point.
      def notify_affected_user
        return unless report.actioned?

        affected = report.reported_user
        return if affected.blank?
        return unless affected.respond_to?(:email) && affected.email.present?

        delivered = Moderate.notify(
          :affected_user_decision,
          subject: report,
          actor: moderator,
          recipients: [affected],
          payload: decision_payload.merge(
            summary: "Statement of reasons for Report ##{report.id}"
          )
        )

        report.update_column(:affected_user_notified_at, Time.now) if delivered
      end

      # The shared statement-of-reasons payload (Art. 17(3)). Every field the law
      # wants the affected user to receive is carried here so the host's mailer can
      # render it without recomputing anything:
      #   - action: what was done (the restriction imposed + its scope)
      #   - ground: the legal (DSA legal_reason) or contractual (community category)
      #     basis — `resolution_basis` is the bucket, the moderator note is the prose
      #   - automated: whether automated means participated in detection/decision
      #     (Art. 17(3)(c)) — read off the report's recorded automated_processing
      #   - reason: the moderator's human-readable note
      # The HOST renders the redress/appeal copy (it names the jurisdiction); the gem
      # supplies the data + the report so the host can mint the signed appeal link.
      def decision_payload
        {
          report_id: report.id,
          status: report.status,
          action: action_label,
          resolution_basis: report.resolution_basis,
          # The contractual ground (in-app reports) vs. the legal ground (DSA notices).
          category: report.category,
          legal_reason: report.legal_reason,
          # Art. 17(3)(c) automated-means disclosure. The model captured this at
          # intake (which filter/flag, if any, surfaced the content); we just relay
          # the boolean so a decision email can never claim "No" after a classifier
          # already participated.
          automated: automated_processing_used?,
          reason: report.resolution_note,
          appeal_deadline_at: report.appeal_deadline_at
        }.compact
      end

      def audit_decision(status, actions, note)
        Moderate.audit(
          :report_decision,
          subject: report,
          actor: moderator,
          payload: {
            report_id: report.id,
            status: status,
            reported_user_id: report.reported_user_id,
            reportable_type: report.reportable_type,
            reportable_id: report.reportable_id,
            actions: actions,
            resolution_basis: report.resolution_basis,
            automated: automated_processing_used?,
            appeal_deadline_at: report.appeal_deadline_at,
            note: note,
            summary: "Report ##{report.id} #{status} by moderator"
          }.compact
        )
      end

      # --- Helpers ------------------------------------------------------------

      # A neutral, host-agnostic description of the restriction (Art. 17 "specific
      # restriction imposed"). Deliberately NOT host vocabulary — "content removed"
      # / "account suspended" are domain-neutral.
      def action_label
        actions = report.resolution_actions.to_h
        return "account_suspended" if truthy?(actions["ban_user"])
        return "content_removed" if truthy?(actions["remove_content"])
        return "no_action" if report.dismissed?

        "other_restriction"
      end

      # Records the *scope* of the restriction in the report's own column for the
      # statement of reasons. Same neutral vocabulary as action_label.
      def decision_visibility_for(status, actions)
        return "no_restriction" unless status == "actioned"
        return "account_suspended" if actions[:ban_user]
        return "content_removed" if actions[:remove_content]

        "other_restriction"
      end

      def automated_processing_used?
        report.respond_to?(:automated_processing_used?) && report.automated_processing_used?
      end

      # Mandatory-note guard. We mutate the record's errors (not raise a bare string)
      # so a controller's `rescue ActiveRecord::RecordInvalid` / `report.errors`
      # flow works exactly like any failed save.
      def require_note!(note)
        normalized = note.to_s.strip
        return normalized unless normalized.empty?

        report.errors.add(:resolution_note, :blank)
        raise ActiveRecord::RecordInvalid, report
      end

      def already_closed_message
        # Fall back to a plain string if I18n isn't available (plain-Ruby contexts);
        # the host can override the key in its locale files.
        if defined?(I18n)
          I18n.t("moderate.errors.report_already_closed", default: "This report has already been resolved.")
        else
          "This report has already been resolved."
        end
      end

      # Boolean cast that works with form params ("1"/"true"/"0") and real booleans,
      # without depending on ActiveModel being loaded in a plain-Ruby context.
      def truthy?(value)
        if defined?(ActiveModel::Type::Boolean)
          ActiveModel::Type::Boolean.new.cast(value) || false
        else
          [true, "1", "true", "t", "yes", "y", 1].include?(value)
        end
      end
    end
  end
end
