# frozen_string_literal: true

module Moderate
  module Services
    # ResolveFlag — the decision on a `Moderate::Flag`, behind the flag's
    # `action!` / `dismiss!` (and `resolve!`, the queue-wide verb).
    #
    # A Flag is a SYSTEM-raised queue item (the wordlist/image/external classifier
    # tripped on a `:flag`-mode field, or an administrator filed one by hand) — it's
    # the "ongoing moderation" surface Apple Guideline 1.2 and Google Play UGC expect:
    #   - https://developer.apple.com/app-store/review/guidelines/#user-generated-content
    #   - https://support.google.com/googleplay/android-developer/answer/9876937
    #
    # Same discipline as every resolver:
    #   - `with_lock` + re-check `pending?` inside the lock for idempotency under
    #     concurrent review (a flag already reviewed is returned as-is: a benign
    #     "already done" suits a fast triage queue);
    #   - a NOTE IS MANDATORY (the moderator's rationale is the audit trail);
    #   - the decision is recorded via `Moderate.audit` (`:flag_decision`).
    #
    # ENFORCEMENT GOES THROUGH A REPORT. A flag carries no reporter, no statement of
    # reasons and no appeal window — but removing content or suspending an account is
    # a restriction, and DSA Art. 17 (statement of reasons) and Art. 20 (appeal) attach
    # to restrictions, not to queue items. So `action!(remove_content: or ban_user:)`
    # ESCALATES: it takes the open report on the same content and field, or opens a
    # system one (no reporter, no receipt), and resolves it through ResolveReport —
    # the one enforcement path in the gem (remove via `remove_reported_field!`, ban via
    # `ban_handler`, the decision notices, the appeal window). All of it happens under
    # the FLAG's row lock, so two moderators pressing "remove" at once enforce once;
    # the decision notices go out after the lock is released, like every decision.
    #
    # Without enforcement options, `action!` is a pure triage close, as before.
    class ResolveFlag
      def initialize(flag, by:)
        @flag = flag
        @moderator = by
      end

      # The flagged content was indeed objectionable — mark the flag actioned, and,
      # when asked, enforce through a report (see the class doc). `resolution_basis`
      # is the report's legal/contractual ground (Report::RESOLUTION_BASES).
      def action!(note:, remove_content: false, ban_user: false, resolution_basis: "terms")
        enforcement = { remove_content: truthy?(remove_content), ban_user: truthy?(ban_user) }
        enforcement = nil unless enforcement.values.any?

        transition!("actioned", note, enforcement: enforcement, resolution_basis: resolution_basis)
      end

      # False positive / acceptable — dismiss the flag.
      def dismiss!(note:)
        transition!("dismissed", note)
      end

      private

      attr_reader :flag, :moderator

      def transition!(status, note, enforcement: nil, resolution_basis: nil)
        note = require_note!(note)
        decision = nil

        flag.with_lock do
          flag.reload

          # Re-check inside the lock. A flag already reviewed is returned as-is (NOT
          # an error) — and nothing is enforced a second time.
          next unless flag.pending?

          report = nil
          if enforcement
            report = escalation_report!(note)
            decision = ResolveReport.new(report, by: moderator, deliver: false)
            decision.resolve!(note: note, resolution_basis: resolution_basis, **enforcement)
          end

          flag.update!(
            status: status,
            resolution_note: note,
            reviewed_by: moderator,
            reviewed_at: Time.current,
            context: report ? flag.context.to_h.merge("report_id" => report.id) : flag.context
          )

          audit_decision(status, note, report)
        end

        # Notify outside the lock, as every decision does: a slow or broken mailer
        # must not hold the row or roll the decision back.
        decision&.deliver_decision_notices
        flag
      end

      # The report enforcement runs through: the newest OPEN report on the same
      # content and field (a person may already have reported what the filter
      # caught), else a system report opened for this decision. A system report has
      # no reporter, so it sends no receipt and no reporter-facing decision; the
      # affected user still gets the statement of reasons and the appeal window.
      def escalation_report!(note)
        existing = Moderate::Report.open
          .where(reportable_type: flag.flaggable_type, reportable_id: flag.flaggable_id, reported_field: flag.field)
          .recent_first
          .first
        return existing if existing

        Moderate::Report.create!(
          reportable: flag.flaggable,
          reported_field: flag.field,
          reported_user: flag.owner,
          intake_kind: "community",
          category: escalation_category,
          message: "Escalated from flag ##{flag.id} (#{flag.source}): #{note}".truncate(Moderate::Report::MESSAGE_MAX_LENGTH),
          good_faith_confirmed: true,
          skip_received_notice: true
        )
      end

      # The flag's own categories speak the classifier taxonomy ("hate",
      # "hate/threatening", "sexual/minors"); keep the first one the host's community
      # list also has, else "other" (or the list's first entry, for a host whose list
      # has no "other").
      def escalation_category
        allowed = Moderate::Report.report_categories
        found = Array(flag.categories).map { |category| category.to_s.split("/").first }.find { |category| allowed.include?(category) }
        found || (allowed.include?("other") ? "other" : allowed.first)
      end

      def audit_decision(status, note, report)
        Moderate.audit(
          :flag_decision,
          subject: flag,
          actor: moderator,
          payload: {
            flag_id: flag.id,
            flaggable_type: flag.flaggable_type,
            flaggable_id: flag.flaggable_id,
            field: flag.field,
            field_label: flag.field_label,
            source: flag.source,
            categories: flag.categories,
            report_id: report&.id,
            note: note,
            summary: "Flag ##{flag.id} #{status} by moderator"
          }.compact
        )
      end

      def require_note!(note)
        normalized = note.to_s.strip
        return normalized unless normalized.empty?

        flag.errors.add(:resolution_note, :blank)
        raise ActiveRecord::RecordInvalid, flag
      end

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end
    end
  end
end
