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

          decision, report = enforce!(note, enforcement, resolution_basis) if enforcement
          close!(status, note, report)
        end

        # Notify outside the lock and after the commit, as every decision does: a
        # slow or broken mailer must not hold the row or roll the decision back.
        Moderate.after_commit { decision.deliver_decision_notices } if decision
        flag
      end

      # Enforce under the CONTENT's row lock too (after the flag's, before the
      # report's — the gem's one lock order), so two flags on the same content can't
      # both enforce: the second waits, then finds the decision the first took.
      # Returns [the ResolveReport that decided, or nil, the report the flag answers to].
      def enforce!(note, enforcement, resolution_basis)
        Moderate.with_row_lock(flag.flaggable) do
          prior = covering_decision(enforcement)
          next [nil, prior] if prior

          report = escalation_report!(note)
          decision = ResolveReport.new(report, by: moderator, deliver: false)
          decision.resolve!(note: note, resolution_basis: resolution_basis, **enforcement)
          [decision, report]
        end
      end

      # A report on the same content and field, decided since this flag was filed,
      # that already did everything asked now (removed it, banned the person). The
      # flag closes against it instead of restricting a second time.
      def covering_decision(enforcement)
        asked = enforcement.select { |_action, wanted| wanted }.keys.map(&:to_s)
        decided = Moderate::Report.actioned.where(same_content).where(resolved_at: flag.created_at..).recent_first
        decided.find { |report| asked.all? { |action| truthy?(report.resolution_actions.to_h[action]) } }
      end

      def close!(status, note, report)
        context = report ? flag.context.to_h.merge("report_id" => report.id) : flag.context
        flag.update!(status: status, resolution_note: note, reviewed_by: moderator, reviewed_at: Time.current,
                     context: context)
        audit_decision(status, note, report)
      end

      # The report enforcement runs through: the newest OPEN report on the same
      # content and field (a person may already have reported what the filter
      # caught), else a system report opened for this decision. A system report has
      # no reporter, so it sends no receipt and no reporter-facing decision; the
      # affected user still gets the statement of reasons and the appeal window.
      def escalation_report!(note)
        existing = Moderate::Report.open.where(same_content).recent_first.first
        return disclose_automation!(existing) if existing

        system_report!(note)
      end

      def same_content
        { reportable_type: flag.flaggable_type, reportable_id: flag.flaggable_id, reported_field: flag.field }
      end

      # A system report opened for this decision. It may name any field the flag is
      # on (`escalated_from_flag`): a filtered field (an image, say) needn't be one a
      # PERSON may report for the gem to enforce on it.
      def system_report!(note)
        message = "Escalated from flag ##{flag.id} (#{flag.source}): #{note}"
        Moderate::Report.create!(
          reportable: flag.flaggable, reported_field: flag.field, reported_user: flag.owner,
          intake_kind: "community", category: escalation_category,
          message: message.truncate(Moderate::Report::MESSAGE_MAX_LENGTH),
          good_faith_confirmed: true, skip_received_notice: true, escalated_from_flag: flag
        )
      end

      # A person's report filed BEFORE a classifier flagged the same content never
      # saw that flag, so its automated-means disclosure (DSA Art. 17(3)(c)) says
      # "no". When the flag is what's being enforced, the decision must say "yes":
      # merge the flag's evidence in first. A manual flag is a person, not automation.
      def disclose_automation!(report)
        return report if flag.source == "manual"

        evidence = report.automated_processing.to_h
        report.update_column(:automated_processing, evidence.merge(
          "used" => true,
          "flag_ids" => Array(evidence["flag_ids"]) | [flag.id],
          "sources" => Array(evidence["sources"]) | [flag.source],
          "categories" => Array(evidence["categories"]) | Array(flag.categories)
        ))
        report
      end

      # The flag's own categories speak the classifier taxonomy ("hate",
      # "hate/threatening", "sexual/minors"); keep the first one the host's community
      # list also has, else "other" (or the list's first entry, for a host whose list
      # has no "other").
      def escalation_category
        allowed = Moderate::Report.report_categories
        top_level = Array(flag.categories).map { |category| category.to_s.split("/").first }
        found = top_level.find { |category| allowed.include?(category) }
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
