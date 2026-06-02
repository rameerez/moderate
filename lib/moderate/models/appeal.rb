# frozen_string_literal: true

module Moderate
  # A DSA Art. 20 internal complaint against a moderation decision.
  #
  # The Digital Services Act requires platforms to give affected users an
  # "effective internal complaint-handling system" that is FREE, ELECTRONIC, open
  # for AT LEAST SIX MONTHS after the decision, and decided by a HUMAN (not "solely
  # on the basis of automated means"). This model encodes each of those:
  #   - free + electronic: it's just a record + a queue (no payment path exists);
  #   - six-month window: an appeal is refused once the report's appeal window has
  #     closed (`report_must_still_be_appealable`);
  #   - human-decided: there is no auto-decide path — uphold!/reject! (in a service)
  #     require a moderator and a note;
  #   - against a DECISION: an appeal can only be opened on an already-resolved
  #     report (`report_must_be_closed`).
  # Source: https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Art. 20)
  class Appeal < ApplicationRecord
    self.table_name = "moderate_appeals"

    # Mirrors the `moderate_appeals_status_check` DB constraint. `upheld` overturns
    # the original decision; `rejected` confirms it.
    STATUSES = %w[open upheld rejected].freeze

    # Who lodged the complaint. `notifier` = the person who filed the original
    # notice; `affected_user` = the content owner whose content was actioned; the
    # rest are operational. Mirrors the `moderate_appeals_source_check` constraint.
    SOURCES = %w[notifier affected_user admin other].freeze

    belongs_to :report, class_name: "Moderate::Report"
    # Appellant may be a logged-in user OR an emailed notifier (public DSA notices
    # come from non-users), so it's optional and we also carry name/email columns.
    belongs_to :appellant, class_name: Moderate.config.user_class, optional: true
    belongs_to :resolved_by, class_name: Moderate.config.user_class, optional: true

    before_validation :normalize_strings
    before_validation :hydrate_appellant_contact, if: :appellant
    before_validation :capture_snapshot, on: :create
    # Default the JSON `snapshot` to {} before save. The migration makes it NOT NULL,
    # but MySQL 8+ forbids a DEFAULT on a JSON column, so without this an appeal whose
    # `capture_snapshot` produced an empty hash that got dropped (or any direct build)
    # could write NULL and trip a NotNullViolation. (SQLite/PostgreSQL get the {}
    # default from the migration; coalescing is harmless there.)
    before_save :default_json_columns

    scope :open, -> { where(status: "open") }
    scope :upheld, -> { where(status: "upheld") }
    scope :rejected, -> { where(status: "rejected") }
    # `pending` mirrors `open`, named for the queue's vocabulary (an appeal awaiting
    # a human decision) — `Moderate::Appeal.pending` is the documented admin scope.
    scope :pending, -> { where(status: "open") }
    scope :recent_first, -> { order(created_at: :desc) }

    validates :status, inclusion: { in: STATUSES }
    validates :source, inclusion: { in: SOURCES }
    # Reuse the Report's message length cap so a complaint and a notice share one
    # limit (and one DB constraint shape).
    validates :reason, presence: true, length: { maximum: Report::MESSAGE_MAX_LENGTH }
    # The complainant must be reachable to receive the appeal decision (Art. 20
    # requires informing them of the outcome), so an email is mandatory here even
    # though the original notice's may not have been.
    validates :appellant_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :resolution_note, presence: true, if: :closed?
    validate :report_must_be_closed
    validate :report_must_still_be_appealable

    def open?
      status == "open"
    end

    def closed?
      status.in?(%w[upheld rejected])
    end

    def upheld?
      status == "upheld"
    end

    def rejected?
      status == "rejected"
    end

    private

    # See the before_save comment: keep the NOT-NULL JSON `snapshot` non-null on MySQL.
    def default_json_columns
      self.snapshot ||= {}
    end

    def normalize_strings
      self.status = status.to_s.squish.presence || "open"
      self.source = source.to_s.squish.presence || "notifier"
      self.appellant_name = appellant_name.to_s.squish.presence
      self.appellant_email = appellant_email.to_s.squish.presence&.downcase
      self.reason = reason.to_s.gsub(/\r\n?/, "\n").strip.presence
      self.resolution_note = resolution_note.to_s.strip.presence
    end

    # Carry the logged-in appellant's contact onto the appeal so the decision can be
    # delivered the same way whether the appellant is a user or an emailed notifier.
    # Read via `try` so the host's user class only needs whichever attribute it has.
    def hydrate_appellant_contact
      self.appellant_email ||= appellant.try(:email)
      self.appellant_name ||= appellant.try(:display_name)
    end

    # Snapshot the DECISION being appealed at the moment the appeal is filed, so the
    # complaint is anchored to exactly what was decided even if the report is later
    # re-resolved. Mirrors the Report's evidence-snapshot philosophy.
    def capture_snapshot
      self.snapshot = {
        report_id: report_id,
        report_status: report&.status,
        report_resolution_basis: report&.resolution_basis,
        report_resolution_actions: report&.resolution_actions,
        report_resolved_at: report&.resolved_at&.iso8601,
        captured_at: Time.current.iso8601
      }.compact
    end

    # You can only appeal a DECISION — an appeal presupposes the report was resolved.
    # We key off `resolved_at` (set when a moderator acts) rather than `status` so a
    # report reopened for any reason can't be appealed in limbo.
    def report_must_be_closed
      return if report&.resolved_at.present?

      errors.add(:report, I18n.t("moderate.errors.appeal_report_must_be_closed", default: "decision can only be appealed after it is made"))
    end

    # Enforce the DSA Art. 20 six-month window: refuse appeals filed after the
    # report's `appeal_deadline_at` (stamped to decision-time + APPEAL_WINDOW). If no
    # deadline was stamped yet, we don't block — the window simply hasn't been opened.
    def report_must_still_be_appealable
      return if report.blank? || report.appeal_deadline_at.blank?
      return if Time.current <= report.appeal_deadline_at

      errors.add(:report, I18n.t("moderate.errors.appeal_window_expired", default: "the appeal window for this decision has closed"))
    end
  end
end
