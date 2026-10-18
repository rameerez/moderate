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
    # NOT NULL). Also how a second run knows a row is already done.
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
    # would change, with `dry_run: true`). Audited as `:retention_purged` when
    # anything changed. Idempotent: a second run finds nothing left to do.
    def self.purge(older_than: DEFAULT_AGE, now: Time.current, dry_run: false)
      age = older_than.to_i
      if older_than.nil? || age < minimum_age.to_i
        raise ArgumentError,
              "older_than must be at least the #{minimum_age.inspect} appeal window (got #{older_than.inspect}): " \
              "a decision that can still be appealed keeps its evidence"
      end

      cutoff = now - older_than
      scopes = {
        reports: reports_due(cutoff, now),
        flags: flags_due(cutoff),
        appeals: appeals_due(cutoff)
      }
      return scopes.transform_values(&:count) if dry_run

      counts = {
        reports: redact(scopes[:reports], report_redaction(now)),
        flags: redact(scopes[:flags], flag_redaction(now)),
        appeals: redact(scopes[:appeals], appeal_redaction(now))
      }
      audit(counts, cutoff: cutoff, older_than: age) if counts.values.sum.positive?
      counts
    end

    # Closed reports decided before `cutoff`, out of their appeal window and with
    # no appeal still open, not redacted yet.
    def self.reports_due(cutoff, now)
      reports = Moderate::Report
      open_appeals = Moderate::Appeal.pending.select(:report_id)

      reports.where(status: reports::STATUSES - ["open"])
        .where(resolved_at: ..cutoff)
        .where(reports.arel_table[:appeal_deadline_at].eq(nil).or(reports.arel_table[:appeal_deadline_at].lteq(now)))
        .where.not(id: open_appeals)
        .where.not(message: REDACTED)
    end

    def self.flags_due(cutoff)
      flags = Moderate::Flag
      flags.where(status: flags::STATUSES - ["pending"])
        .where(reviewed_at: ..cutoff)
        .merge(flags.where(excerpt: nil).or(flags.where.not(excerpt: REDACTED)))
    end

    def self.appeals_due(cutoff)
      appeals = Moderate::Appeal
      appeals.where(status: appeals::STATUSES - ["open"])
        .where(resolved_at: ..cutoff)
        .where.not(reason: REDACTED)
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
        updated_at: now
      }
    end

    def self.flag_redaction(now)
      { excerpt: REDACTED, context: { "redacted_at" => now.iso8601 }, updated_at: now }
    end

    def self.appeal_redaction(now)
      { reason: REDACTED, appellant_name: nil, appellant_email: nil, updated_at: now }
    end

    # One UPDATE per batch, no callbacks or validations: a redacted DSA notice no
    # longer carries the notifier details its validations ask for, and nothing
    # should re-save a final record anyway.
    def self.redact(scope, attributes)
      changed = 0
      scope.in_batches(of: 500) { |batch| changed += batch.update_all(attributes) }
      changed
    end

    def self.audit(counts, cutoff:, older_than:)
      Moderate.audit(
        :retention_purged,
        payload: counts.merge(
          cutoff: cutoff.iso8601,
          older_than_seconds: older_than,
          summary: "retention: redacted #{counts[:reports]} reports, #{counts[:flags]} flags, " \
                   "#{counts[:appeals]} appeals decided before #{cutoff.to_date}"
        )
      )
    end

    private_class_method :reports_due, :flags_due, :appeals_due, :report_redaction, :flag_redaction,
                         :appeal_redaction, :redact, :audit
  end
end
