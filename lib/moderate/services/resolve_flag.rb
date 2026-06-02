# frozen_string_literal: true

module Moderate
  module Services
    # ResolveFlag — the decision on an auto-filter `Moderate::Flag`, behind the
    # flag's `action!` / `dismiss!`.
    #
    # A Flag is a SYSTEM-raised queue item (the wordlist/image/external classifier
    # tripped on a `:flag`-mode field, or a human filed one manually) — it's the
    # "ongoing moderation" surface Apple Guideline 1.2 and Google Play UGC expect:
    #   - https://developer.apple.com/app-store/review/guidelines/#user-generated-content
    #   - https://support.google.com/googleplay/android-developer/answer/9876937
    #
    # A flag is lighter than a report: there's no reporter to inform and no appeal
    # window to stamp (an appeal attaches to a *report* decision, not to a raw
    # queue item). So this service is the simplest of the resolvers — atomic
    # transition, mandatory note, audit — but it follows the same discipline:
    #   - `with_lock` + re-check `pending?` inside the lock for idempotency under
    #     concurrent review;
    #   - a NOTE IS MANDATORY (the moderator's rationale is the audit trail);
    #   - the decision is recorded via `Moderate.audit`, never a host-specific log.
    #
    # NOTE: unlike ResolveReport, resolving a flag does NOT itself run content
    # removal/bans. A flag marks "this needs a look"; the enforcement decision is a
    # *report* concern. If a moderator wants to remove the flagged content, they file
    # /resolve a report on it. This keeps the flag a pure triage record and avoids
    # two divergent enforcement paths. (Documented so a maintainer doesn't "helpfully"
    # add removal here and create that divergence.)
    class ResolveFlag
      def initialize(flag, by:)
        @flag = flag
        @moderator = by
      end

      # The flagged content was indeed objectionable — mark the flag actioned. (Any
      # actual takedown is done by acting on a report; see the class note.)
      def action!(note:)
        transition!("actioned", note)
      end

      # False positive / acceptable — dismiss the flag.
      def dismiss!(note:)
        transition!("dismissed", note)
      end

      private

      attr_reader :flag, :moderator

      def transition!(status, note)
        note = require_note!(note)

        flag.with_lock do
          flag.reload

          # Re-check inside the lock. A flag already reviewed is returned as-is (NOT
          # an error): unlike a report, double-reviewing a flag is harmless and a
          # benign "already done" is friendlier for a fast triage queue.
          return flag unless flag.pending?

          flag.update!(
            status: status,
            resolution_note: note,
            reviewed_by: moderator,
            reviewed_at: Time.now
          )

          audit_decision(status, note)
        end

        flag
      end

      def audit_decision(status, note)
        Moderate.audit(
          :flag_decision,
          subject: flag,
          actor: moderator,
          payload: {
            flag_id: flag.id,
            flaggable_type: flag.flaggable_type,
            flaggable_id: flag.flaggable_id,
            field: flag.field,
            source: flag.source,
            categories: flag.categories,
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
    end
  end
end
