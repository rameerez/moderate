# frozen_string_literal: true

module Moderate
  # Opt-in retention: strip the personal data out of moderation records nobody can
  # act on any more, and keep the decisions.
  #
  #   Moderate.purge(older_than: 1.year)                # what a nightly job runs
  #   Moderate.purge(older_than: 18.months, dry_run: true)  # => counts, nothing changed
  #   bin/rails moderate:purge OLDER_THAN_DAYS=365 DRY_RUN=1
  #
  # Nothing in the gem calls this: until a host schedules it, every report, flag,
  # appeal and block is kept as it was written. docs/compliance.md ("Retention")
  # says what is stored, what this removes, and why the rest stays.
  #
  # What it touches — only records whose decision is final:
  #
  #   * a REPORT (in-app report or DSA notice) that is closed, was decided more than
  #     `older_than` ago, whose appeal window has closed, and that has no open
  #     appeal: its message, evidence snapshot, reported URLs, reported account
  #     identifier, notifier name and email, and reporter are removed;
  #   * a FLAG that was decided more than `older_than` ago: its excerpt and its
  #     context (the classifier's raw response, a reviewer's note) are removed;
  #   * an APPEAL that was decided more than `older_than` ago: its reason and the
  #     appellant's name and email are removed.
  #
  # What it keeps: every row, with its type, category, legal ground, member state,
  # content type, status, timestamps, the decision (resolution basis, actions,
  # note, decision visibility, automated-means disclosure) and who it was about
  # (reported user, flag owner). Those are the statement of reasons, the record a
  # repeat-misuse policy (DSA Art. 23) and a legal claim rely on, and what
  # `Moderate.transparency` counts, so a published Art. 15/24 report stays
  # reproducible. Blocks are never touched: they are live safety state, not a
  # record of the past, and go when either person unblocks or is deleted.
  #
  # Pending reports, flags and appeals are never touched, whatever their age.
  module Retention
    # What a removed text column reads afterwards (message, excerpt and reason are
    # NOT NULL). Only a filler: whether a row is done is its `redacted_at`.
    REDACTED = "[redacted]"

    # The default age, counted from the decision. Six months of appeal window
    # (Art. 20), the time an out-of-court dispute settlement body may take (Art. 21),
    # and a margin for a complaint or legal claim that arrives late.
    DEFAULT_AGE = 1.year

    # `older_than` may not be shorter than the appeal window: a decision that can
    # still be appealed must keep its evidence.
    def self.minimum_age
      Moderate::Report::APPEAL_WINDOW
    end

    # Redact what is old enough, and return how many rows of each kind changed (or
    # would change, with `dry_run: true`), plus, under `:held`, how many were old
    # enough but kept for a legal hold. Audited as `:retention_purged` when anything
    # changed. Idempotent: a row is selected while its `redacted_at` is nil, whatever
    # its content says, and stamped when it is redacted.
    #
    #   Moderate.purge  # => { reports: 3, flags: 9, appeals: 1, classifications: 40,
    #                   #      held: { reports: 1, flags: 2, appeals: 0 } }
    def self.purge(older_than: DEFAULT_AGE, now: Time.current, dry_run: false)
      age = older_than.to_i
      if older_than.nil? || age < minimum_age.to_i
        raise ArgumentError,
          "older_than must be at least the #{minimum_age.inspect} appeal window (got #{older_than.inspect}): " \
          "a decision that can still be appealed keeps its evidence"
      end

      cutoff = now - older_than
      due = { reports: reports_due(cutoff, now), flags: flags_due(cutoff), appeals: appeals_due(cutoff) }
      held = due.to_h { |kind, scope| [kind, scope.where(hold_condition(kind, now, held: true)).count] }
      free = due.to_h { |kind, scope| [kind, scope.where(hold_condition(kind, now, held: false))] }
      classifications = classifications_due(cutoff, now)
      kept = { claims_kept: live_claims(cutoff, now).count, held: held }
      return free.transform_values(&:count).merge(classifications: classifications.count, **kept) if dry_run

      counts = {
        reports: redact(free[:reports], report_redaction(now)),
        flags: redact(free[:flags], flag_redaction(now)),
        appeals: redact(free[:appeals], appeal_redaction(now)),
        classifications: delete(classifications)
      }
      audit(counts, held, cutoff: cutoff, older_than: age) if counts.values.sum.positive?
      counts.merge(kept)
    end

    # Put `report` under a legal hold until `until:` (a future time): the purge leaves
    # the report, its appeals and the flags on its content alone, however old they
    # are — an out-of-court dispute (DSA Art. 21), a court case, an authority's
    # request. Placing it again moves the date (later or earlier). Audited as
    # `:legal_hold_placed`.
    def self.hold(report, until:, by: nil, reason: nil)
      held_until = binding.local_variable_get(:until)
      unless held_until.respond_to?(:to_time) && held_until.to_time > Time.current
        raise ArgumentError, "a legal hold needs a time in the future (until: #{held_until.inspect})"
      end

      report.update_columns(held_until: held_until, updated_at: Time.current)
      Moderate.audit(:legal_hold_placed, **hold_event(report, by: by, reason: reason, held_until: held_until))
      report
    end

    # Lift `report`'s legal hold: the next purge treats it like any other report.
    # Audited as `:legal_hold_released`. A report with no hold is returned unchanged.
    def self.release_hold(report, by: nil, reason: nil)
      return report if report.held_until.nil?

      report.update_columns(held_until: nil, updated_at: Time.current)
      Moderate.audit(:legal_hold_released, **hold_event(report, by: by, reason: reason, held_until: nil))
      report
    end

    # Closed reports decided before `cutoff`, out of their appeal window and with
    # no appeal still open, not redacted yet.
    def self.reports_due(cutoff, now)
      reports = Moderate::Report
      open_appeals = Moderate::Appeal.pending.select(:report_id)

      reports.where(status: reports::STATUSES - ["open"], redacted_at: nil)
        .where(resolved_at: ..cutoff)
        .where(reports.arel_table[:appeal_deadline_at].eq(nil).or(reports.arel_table[:appeal_deadline_at].lteq(now)))
        .where.not(id: open_appeals)
    end

    def self.flags_due(cutoff)
      flags = Moderate::Flag
      flags.where(status: flags::STATUSES - ["pending"], redacted_at: nil).where(reviewed_at: ..cutoff)
    end

    # Attachment classification bookkeeping (Moderate::Classification: ids, a digest,
    # timestamps) last touched before `cutoff`: classified then, or a claim nobody
    # completed. Deleted, not redacted: nothing in them is evidence. Never a row with
    # a LIVE claim (younger than config.classification_claim_ttl), whatever its age:
    # a worker is classifying those files right now, and would discard its result.
    def self.classifications_due(cutoff, now)
      rows = Moderate::Classification.arel_table
      Moderate::Classification.where(updated_at: ..cutoff)
        .where(rows[:claimed_at].eq(nil).or(rows[:claimed_at].lt(now - Moderate::Attachments.claim_ttl)))
    end

    # Rows the age cutoff would take but a live claim keeps (`:claims_kept`).
    def self.live_claims(cutoff, now)
      Moderate::Classification.where(updated_at: ..cutoff).where(claimed_at: (now - Moderate::Attachments.claim_ttl)..)
    end

    def self.delete(scope)
      deleted = 0
      scope.in_batches(of: 500) { |batch| deleted += batch.delete_all }
      deleted
    end

    def self.appeals_due(cutoff)
      appeals = Moderate::Appeal
      appeals.where(status: appeals::STATUSES - ["open"], redacted_at: nil).where(resolved_at: ..cutoff)
    end

    # Arel for "kept by a legal hold" (held: true) or "not" (held: false): the
    # report's own hold; an appeal's report's; for a flag, a held report on the same
    # content and field (or on the whole record). Written both ways rather than
    # negated, because NOT (held_until > now) is NULL, not true, for a report that
    # was never held.
    def self.hold_condition(kind, now, held:)
      reports = Moderate::Report.arel_table
      held_reports = Moderate::Report.where(reports[:held_until].gt(now))
      case kind
      when :reports
        held ? reports[:held_until].gt(now) : reports[:held_until].eq(nil).or(reports[:held_until].lteq(now))
      when :appeals
        ids = held_reports.select(:id).arel
        held ? Moderate::Appeal.arel_table[:report_id].in(ids) : Moderate::Appeal.arel_table[:report_id].not_in(ids)
      when :flags
        flags = Moderate::Flag.arel_table
        same_content = held_reports
          .where(reports[:reportable_type].eq(flags[:flaggable_type]))
          .where(reports[:reportable_id].eq(flags[:flaggable_id]))
          .where(reports[:reported_field].eq(flags[:field]).or(reports[:reported_field].eq(nil)))
          .arel.exists
        held ? same_content : same_content.not
      end
    end

    def self.report_redaction(now)
      {
        message: REDACTED,
        snapshot: { "redacted_at" => now.iso8601 },
        subject_url: nil,
        subject_urls: [],
        reported_account_identifier: nil,
        notifier_name: nil,
        notifier_email: nil,
        reporter_id: nil,
        redacted_at: now,
        updated_at: now
      }
    end

    def self.flag_redaction(now)
      { excerpt: REDACTED, context: { "redacted_at" => now.iso8601 }, redacted_at: now, updated_at: now }
    end

    def self.appeal_redaction(now)
      { reason: REDACTED, appellant_name: nil, appellant_email: nil, redacted_at: now, updated_at: now }
    end

    # One UPDATE per batch, no callbacks or validations: a redacted DSA notice no
    # longer carries the notifier details its validations ask for, and nothing
    # should re-save a final record anyway.
    def self.redact(scope, attributes)
      changed = 0
      scope.in_batches(of: 500) { |batch| changed += batch.update_all(attributes) }
      changed
    end

    def self.audit(counts, held, cutoff:, older_than:)
      Moderate.audit(
        :retention_purged,
        payload: counts.merge(
          held: held,
          cutoff: cutoff.iso8601,
          older_than_seconds: older_than,
          summary: "retention: redacted #{counts[:reports]} reports, #{counts[:flags]} flags, " \
                   "#{counts[:appeals]} appeals decided before #{cutoff.to_date}; deleted " \
                   "#{counts[:classifications]} classification rows"
        )
      )
    end

    def self.hold_event(report, by:, reason:, held_until:)
      {
        subject: report,
        actor: by,
        payload: {
          report_id: report.id, held_until: held_until&.iso8601, reason: reason,
          summary: held_until ? "Report ##{report.id} held until #{held_until.to_date}" : "Report ##{report.id} hold released"
        }.compact
      }
    end

    private_class_method :reports_due, :flags_due, :appeals_due, :classifications_due, :live_claims, :delete,
      :hold_condition, :report_redaction, :flag_redaction, :appeal_redaction, :redact, :audit, :hold_event
  end
end
