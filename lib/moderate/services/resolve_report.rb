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
      # The decision notices are queued on the report and sent when the outermost
      # transaction commits (Moderate::DeferredNotices). `deliver: false` leaves them
      # to a caller that queues them on a record of its own (ResolveFlag, on the flag),
      # via `#deliver_decision_notices`.
      #
      # `conduct_since:` is when the conduct this decision answers was first raised —
      # the report's own creation by default; ResolveFlag passes the flag's. A ban
      # decided on the same person since then already answered it (see
      # #ban_reported_user!).
      def initialize(report, by:, deliver: true, conduct_since: nil)
        @report = report
        @moderator = by
        @deliver = deliver
        @conduct_since = conduct_since
      end

      # The report being decided.
      attr_reader :report

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

        # A ban nothing would apply is refused before anything changes (see
        # Moderate.ensure_ban_handler!): never "account suspended" for a suspension
        # that didn't happen.
        Moderate.ensure_ban_handler! if actions[:ban_user] && report.reported_user.present?

        transition!("actioned", note: note, actions: actions) do
          remove_reported_content!(note: note) if actions[:remove_content]
          ban_reported_user!(note: note, actions: actions) if actions[:ban_user]
        end
      end

      # Dismiss (no violation found). Still requires a note (Art. 17 applies to the
      # reporter's right to know the outcome too) and still opens an appeal window —
      # the *reporter* can appeal a dismissal.
      def dismiss!(note:)
        note = require_note!(note)
        transition!("dismissed", note: note, actions: { resolution_basis: "no_violation" })
      end

      # The two decision events (see the class doc, point 4). Sent by `resolve!` /
      # `dismiss!` themselves unless this service was built with `deliver: false`.
      def deliver_decision_notices
        notify_user_banned
        notify_reporter
        notify_affected_user
        notify_content_removed
      end

      private

      attr_reader :moderator

      # The atomic core. Everything that mutates state happens under the row lock;
      # the (slow, fallible) notifications happen AFTER the lock is released, so a
      # broken mailer can't hold a database lock or roll back the decision.
      def transition!(status, note:, actions:, &enforcement)
        # One lock order everywhere: content, then (for a ban) the person, then the
        # report — the order a flag escalation takes too, so they never deadlock. The
        # person's lock serializes two bans of one account from different content.
        Moderate.with_row_lock(report.reportable) do
          Moderate.with_row_lock(actions[:ban_user] ? report.reported_user : nil) do
            lock_and_transition!(status, note: note, actions: actions, &enforcement)
          end
        end

        report
      end

      def lock_and_transition!(status, note:, actions:)
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

          # Sent when the outermost transaction commits, never on a rollback.
          report.after_commit_notice { deliver_decision_notices } if @deliver
        end
      end

      # --- Enforcement (host contracts only) ----------------------------------

      # The reportable's own removal (`remove_reported_field!`). When it says it
      # removed something, the removal is audited here, inside the decision's
      # transaction, and announced as `content_removed` with the decision notices.
      def remove_reported_content!(note:)
        # Nothing to remove from (the content was deleted, its report nullified) or
        # no way to remove it: refused like a removal that removed nothing.
        removable = report.reportable.present? && report.reportable.respond_to?(:remove_reported_field!)
        refuse_unremoved! unless removable && report.reportable.remove_reported_field!(report.reported_field)

        @content_removed = content_removed_payload(note)
        Moderate.audit(:content_removed, **content_removed_event)
        true
      end

      # "Remove the content" was asked and the reportable removed nothing (the field
      # isn't removable, or it's already gone). Recording the decision anyway would
      # tell the affected person "content removed" for content that's still there, so
      # the whole decision is refused (and rolled back, a ban with it).
      def refuse_unremoved!
        message = I18n.t(
          "moderate.errors.nothing_removed",
          content: report.reportable_label,
          default: "Nothing was removed: #{report.reportable_label} has nothing removable there (already " \
                   "removed, deleted, or not removable). Resolve without removing content, or dismiss."
        )
        report.errors.add(:base, message)
        raise ActiveRecord::RecordInvalid, report
      end

      def content_removed_payload(note)
        {
          report_id: report.id,
          reportable_type: report.reportable_type,
          reportable_id: report.reportable_id,
          reported_field: report.reported_field,
          reported_field_label: report.reported_field_label,
          reason: note,
          summary: ["Content removed: #{report.reportable_label}", report.reported_field_label].compact.join(" · ")
        }.compact
      end

      def content_removed_event
        { subject: report, actor: moderator, recipients: [report.reported_user].compact, payload: @content_removed }
      end

      # The gem never bans directly — it asks the host's ban_handler what "banned"
      # means (suspend, soft-delete, flip a flag…). ONE ban per person per episode: if
      # a decision on this same person, on any content or field, already banned them
      # since this conduct was raised, the account is suspended already — this decision
      # records which one (`ban_already_applied_by`) instead of banning twice. (An
      # older ban, before this conduct, doesn't count: the person may have been
      # unbanned since, and new conduct deserves its own decision.)
      def ban_reported_user!(note:, actions:)
        user = report.reported_user
        return if user.blank?

        if (prior = prior_ban_decision(user))
          actions[:ban_already_applied_by] = prior.id
          return
        end

        @user_banned = Moderate.apply_ban(user: user, by: moderator, reason: note, announce: false)
      end

      def prior_ban_decision(user)
        since = @conduct_since || report.created_at
        Moderate::Report.actioned.where(reported_user_id: user.id).where(resolved_at: since..).where.not(id: report.id)
          .recent_first.find { |decided| truthy?(decided.resolution_actions.to_h["ban_user"]) }
      end

      # --- Notifications (after the lock) -------------------------------------

      # user_banned → the banned person (Moderate.apply_ban, announced here so it waits
      # for the commit like the rest).
      def notify_user_banned
        return unless @user_banned

        Moderate.announce_ban(**@user_banned)
      end

      # content_removed → the person whose content it was (when there is one) and the
      # host's admin channels. Only when the removal actually removed something.
      def notify_content_removed
        return unless @content_removed

        Moderate.notify(:content_removed, **content_removed_event)
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
      #   - reported_field_label: WHICH content the decision is about, in words the
      #     affected user recognizes ("Chat message", never the column name "body")
      # The HOST renders the redress/appeal copy (it names the jurisdiction); the gem
      # supplies the data + the report so the host can mint the signed appeal link.
      def decision_payload
        {
          report_id: report.id,
          status: report.status,
          action: action_label,
          reported_field: report.reported_field,
          reported_field_label: report.reported_field_label,
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
            reported_field: report.reported_field,
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
