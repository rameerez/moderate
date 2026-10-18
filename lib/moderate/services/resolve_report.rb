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
      #
      # A resolve restricts something: `remove_content:`, `ban_user:`, or both. One with
      # neither is refused (RecordInvalid): recording it would tell the affected person a
      # restriction was imposed when none was. A decision that restricts nothing is a
      # `dismiss!`, whose statement says so.
      def resolve!(note:, remove_content: false, ban_user: false, resolution_basis: "terms")
        note = require_note!(note)
        actions = {
          remove_content: truthy?(remove_content),
          ban_user: truthy?(ban_user),
          resolution_basis: resolution_basis.to_s.strip.presence || "terms"
        }
        require_action!(actions)

        # A ban nothing would apply is refused before anything changes (see
        # Moderate.ensure_ban_handler!): never "account suspended" for a suspension
        # that didn't happen.
        Moderate.ensure_ban_handler! if actions[:ban_user] && report.reported_user.present?

        transition!("actioned", note: note, actions: actions) do
          remove_reported_content!(note: note, actions: actions) if actions[:remove_content]
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
        # The report's connection, captured before anything is saved: every notice of
        # this decision joins ITS transaction, whatever a host callback switches to.
        @connection = Moderate::DeferredNotices.connection_for(report.class)

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
          # `with_lock` already re-read the row under the lock (SELECT … FOR UPDATE):
          # no plain reload here — under MySQL's REPEATABLE READ a plain read pins the
          # transaction's snapshot, and every later check must see what committed.

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
          report.after_commit_notice(on: @connection) { deliver_decision_notices } if @deliver
        end
      end

      # --- Enforcement (host contracts only) ----------------------------------

      # The reportable's own removal (`remove_reported_field!`). When it says it
      # removed something, the removal is audited here, inside the decision's
      # transaction, and announced as `content_removed` with the decision notices.
      def remove_reported_content!(note:, actions:)
        # Already removed by an earlier decision on the same content and field: close
        # against it (like a flag does), the reporter told it's gone, nothing removed
        # or announced a second time.
        if (prior = covering_removal)
          actions[:content_already_removed_by] = prior.id
          return true
        end

        # Nothing to remove from (the content was deleted, its report nullified) or
        # no way to remove it: refused like a removal that removed nothing.
        removable = report.reportable.present? && report.reportable.respond_to?(:remove_reported_field!)
        refuse_unremoved! unless removable && report.reportable.remove_reported_field!(report.reported_field)

        @content_removed = content_removed_payload(note)
        Moderate.audit(:content_removed, **content_removed_event)
        true
      end

      def covered_note
        prior = report.resolution_actions.to_h["content_already_removed_by"]
        prior ? " (already removed by the decision on Report ##{prior})" : ""
      end

      # An actioned report on the same content and field whose decision removed it,
      # while the content is gone NOW (read fresh, under the content's lock: a recorded
      # removal only counts if nothing is there any more). A locking read, like every
      # "already done" check (Moderate.with_row_lock).
      def covering_removal
        type, id = content_ids(report)
        return if type.blank? || id.blank? || !content_gone?

        # Deleting the content nullifies every report's pointer, the earlier one's too:
        # then the candidates are the nullified ones, matched by their snapshots.
        pointer = report.reportable_id ? { reportable_type: type, reportable_id: id } : { reportable_id: nil }
        Moderate::Report.actioned.where(pointer).where(reported_field: report.reported_field)
          .where.not(id: report.id).recent_first.lock
          .find do |prior|
            content_ids(prior) == [type, id] && same_revision?(prior) &&
              truthy?(prior.resolution_actions.to_h["remove_content"])
          end
      end

      # Did `prior` decide on the very revision this report was filed on? Their intake
      # snapshots must carry the same content text and the same content `updated_at`.
      # When either is missing (an older snapshot, a purged one, content with no text),
      # identity can't be established and nothing is covered: a repost into the same
      # field is new content, and an old removal must never be credited for it.
      def same_revision?(prior)
        mine = report.snapshot.to_h.with_indifferent_access
        theirs = prior.snapshot.to_h.with_indifferent_access
        %i[content_text content_updated_at].all? { |key| mine[key].present? && mine[key] == theirs[key] }
      end

      # A report's content type and id, from its snapshot when its own pointer was
      # nullified (the content deleted).
      def content_ids(of)
        snapshot = of.snapshot.to_h.with_indifferent_access
        [of.reportable_type.presence || snapshot[:reportable_type], (of.reportable_id || snapshot[:reportable_id])&.to_s]
      end

      def content_gone?
        content = report.reportable&.reload(lock: true)
        return true if content.nil?
        return true if content.respond_to?(:deleted?) && content.deleted?

        field = report.reported_field
        return false if field.blank?

        value = content.respond_to?(:moderation_field_value, true) ? content.send(:moderation_field_value, field) : content.try(field)
        value.respond_to?(:attached?) ? !value.attached? : value.blank?
      rescue ActiveRecord::RecordNotFound
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
      # records which one (`ban_already_applied_by`) instead of banning twice, unless
      # your `config.banned` says the account isn't banned any more (unbanned in your
      # app since), in which case the ban_handler runs again. (An older ban, before
      # this conduct, doesn't count: the person may have been unbanned since, and new
      # conduct deserves its own decision.)
      def ban_reported_user!(note:, actions:)
        # The person, read again with a locking read now that we hold their lock: a
        # concurrent decision that banned them while we waited has committed, and
        # `config.banned` and the ban_handler must see THAT state, not the copy loaded
        # before the wait.
        user = locked_person
        return if user.blank?

        if (prior = prior_ban_decision(user)) && still_banned?(user)
          actions[:ban_already_applied_by] = prior.id
          return
        end

        @user_banned = Moderate.apply_ban(user: user, by: moderator, reason: note, announce: false)
      end

      def locked_person
        person = report.reported_user
        person && person.class.unscoped.lock.find_by(person.class.primary_key => person.id)
      end

      # An earlier ban of this episode covers this one only while the account is still
      # banned. The host knows that (`config.banned`); without it, the earlier ban counts.
      def still_banned?(user)
        check = Moderate.config.banned
        check.nil? || check.call(user) ? true : false
      end

      def prior_ban_decision(user)
        since = @conduct_since || report.created_at
        decided = Moderate::Report.actioned.where(reported_user_id: user.id, resolved_at: since..)
          .where.not(id: report.id)
        # A locking read: a ban committed by a concurrent decision while we waited for
        # the person's lock is seen, whatever the isolation level.
        decided.recent_first.lock.find { |prior| truthy?(prior.resolution_actions.to_h["ban_user"]) }
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
      # decision + redress). `decision_notified_at` is stamped only when the host's
      # notifier confirms the message actually went out (Moderate.delivered!): a
      # queued mail is not a delivered one, and the timestamp starts the appeal
      # window (Art. 20(2)).
      def notify_reporter
        return if report.notifier_email.blank?

        Moderate.notify(
          :report_decision,
          subject: report,
          actor: moderator,
          recipients: [report.reporter].compact,
          payload: decision_payload.merge(
            summary: "Decision on Report ##{report.id}: #{report.status}" \
                     "#{covered_note}"
          )
        )
      end

      # affected_user_decision → the content owner: the DSA Art. 17 statement of
      # reasons. Only fires when we actually restricted something (an "actioned"
      # decision) and there's an identifiable owner to tell. Carries the action, the
      # ground, the automated-means disclosure, and the appeal entry point.
      def notify_affected_user
        return unless report.actioned?

        # Its removal was already announced by the decision that made it; a second
        # statement only when this one also bans.
        actions = report.resolution_actions.to_h
        return if actions["content_already_removed_by"] && !truthy?(actions["ban_user"])

        affected = report.reported_user
        return if affected.blank?
        return unless affected.respond_to?(:email) && affected.email.present?

        Moderate.notify(
          :affected_user_decision,
          subject: report,
          actor: moderator,
          recipients: [affected],
          payload: decision_payload.merge(
            summary: "Statement of reasons for Report ##{report.id}"
          )
        )
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
          # "Already actioned by decision X": the content was gone when this was decided.
          content_already_removed_by: report.resolution_actions.to_h["content_already_removed_by"],
          # A minimum ("at least until"): confirmed delivery (Moderate.delivered!)
          # can move it later (Art. 20(2)), never earlier.
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

        "content_removed" # resolve! requires one of the two (require_action!)
      end

      def require_action!(actions)
        return if actions[:remove_content] || actions[:ban_user]

        report.errors.add(:base, I18n.t(
          "moderate.errors.resolve_needs_action",
          default: "Resolving a report restricts something: remove the content, ban the account, or both. " \
                   "To close it without a restriction, dismiss it."
        ))
        raise ActiveRecord::RecordInvalid, report
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
