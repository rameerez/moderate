# frozen_string_literal: true

module Moderate
  # A system/auto-filter flag: the record an adapter (or a manual action) leaves
  # behind when content is flagged for review rather than rejected outright.
  #
  # Flags are what `:flag`-mode filtering produces AFTER COMMIT — the write
  # succeeds, then a Flag lands in the queue. This is intentional and load-bearing:
  # a flag must NEVER be created inside a validator/transaction, because a validator
  # is supposed to be side-effect-free and a Flag written inside a transaction that
  # later rolls back would silently vanish (you'd "moderate" content that was never
  # saved). The Filterable concern enforces the after_commit timing; this model is
  # just the record + the queue + the "content flagged" notification.
  #
  # The same `pending` scope serves BOTH a human admin queue and an automated
  # consumer (e.g. a job that auto-actions high-confidence flags), so the gem
  # doesn't presume a human is the only reviewer.
  class Flag < ApplicationRecord
    include Moderate::DeferredNotices
    self.table_name = "moderate_flags"

    STATUSES = %w[pending actioned dismissed].freeze

    # Built-in/generic source names. Host-registered adapter names are also valid
    # sources (see `.sources` below) because `Moderate.classify` stamps the adapter
    # name onto the Result when the adapter does not set one explicitly. This is why
    # a host can register `:openai` or `:image` and see that exact name in the queue.
    SOURCES = %w[text_filter image_filter external_classifier manual].freeze

    # What the flag WOULD do. `:flag` allowed the write and queued it; `:block`
    # rejected the write (a block-mode trip can also be recorded as a flag for the
    # audit trail). Validated by the model (inclusion), not a DB constraint.
    MODES = %w[flag block].freeze

    # The flagged content is polymorphic — any `Moderate::Reportable`. `owner` is the
    # responsible user (inferred from the flaggable's `reported_owner`), kept here so
    # the queue can group flags by user without re-resolving ownership; optional
    # because not all content has a single owning account. `reviewed_by` is the
    # moderator who closed it. All user associations resolve to the host's configured
    # user class, read lazily from config as a String.
    belongs_to :flaggable, polymorphic: true
    belongs_to :owner, class_name: Moderate.config.user_class, optional: true
    belongs_to :reviewed_by, class_name: Moderate.config.user_class, optional: true

    # Default the JSON columns to their empty shape before save: `categories` is a
    # list ([]), `scores`/`context` are hashes ({}). The migration makes all three
    # NOT NULL, but MySQL 8+ forbids a JSON DEFAULT, so a Flag built directly (rather
    # than via `flag!`, which already coerces them) could write NULL and trip a
    # NotNullViolation on MySQL. (SQLite/PostgreSQL get the defaults from the
    # migration; coalescing is harmless there.)
    before_save :default_json_columns

    # Announce a new flag through the host's notify hook so admins get pinged (e.g.
    # a Telegram alert) the moment content is flagged. after_create_COMMIT, not
    # after_create: the flag must be durably saved before we tell anyone about it,
    # and the notify must not be able to roll the flag back.
    after_create_commit :notify_content_flagged

    scope :pending, -> { where(status: "pending") }
    scope :actioned, -> { where(status: "actioned") }
    scope :dismissed, -> { where(status: "dismissed") }
    scope :recent_first, -> { order(created_at: :desc) }

    validates :field, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :source, inclusion: { in: ->(_flag) { sources } }, on: :create
    validates :mode, inclusion: { in: MODES }
    validates :resolution_note, presence: true, if: :closed?

    # The single entry point the Filterable concern uses to file a flag. Centralizes
    # coercion (categories → Array, scores/context → Hash) so callers can hand us
    # whatever shape a Moderate::Result exposed without each one re-normalizing.
    # `context` is freeform JSON for audit (which policy fired, the raw classifier
    # payload, etc.) — never relied on by the gem's own logic.
    #
    # `owner` is kept only if it is a person (the configured user class): hosts
    # commonly pass `record.reported_owner`, which can be a desk or a bot.
    def self.flag!(flaggable:, field:, owner:, source:, mode:, excerpt:, categories:, scores:, context:)
      create!(
        flaggable: flaggable,
        field: field,
        owner: (owner if owner.is_a?(Moderate.user_class)),
        source: source,
        mode: mode,
        excerpt: excerpt,
        categories: Array(categories),
        scores: scores.to_h,
        context: context.to_h
      )
    end

    # An administrator filing `record`'s `field` for review by hand — the "Flag for
    # review" button on a transcript line or a profile page. It lands in the same
    # `pending` queue the filters feed, to be decided like any other flag. Nothing is
    # removed or sanctioned here.
    #
    #   flag = Moderate::Flag.flag_for_review!(message, field: :body, by: current_user)
    #   flag.previously_new_record?   # => true if filed now, false if one already waited
    #
    # ONCE per field: if a pending flag on that field already waits, it is returned
    # instead of a second one. The check and the insert run under the RECORD's row
    # lock, so two administrators pressing it together file one flag (a check-then-
    # insert without the lock files two). The record must be persisted.
    #
    # The flag is `source: "manual"`, owned by the person responsible for the record
    # (Moderate.responsible_user), with an excerpt from the record's evidence snapshot
    # (or the field's text), and `context` naming who filed it and their note. The
    # filing is audited as `:flag_filed` with the administrator as actor.
    def self.flag_for_review!(record, field:, by:, note: nil)
      field_s = field.to_s.strip
      raise ArgumentError, "field is required" if field_s.empty?
      unless record.respond_to?(:persisted?) && record.persisted?
        raise ArgumentError, "#{record.class.name} must be persisted to be flagged"
      end

      note = note.to_s.strip.presence
      flag = Moderate.with_row_lock(record) do
        where(flaggable: record, field: field_s).pending.recent_first.lock.first ||
          file_for_review!(record, field_s, by: by, note: note)
      end
      audit_filed_for_review(flag, by: by, note: note) if flag.previously_new_record?
      flag
    end

    def self.file_for_review!(record, field, by:, note:)
      flag!(
        flaggable: record, field: field, owner: Moderate.responsible_user(record),
        source: "manual", mode: "flag", excerpt: review_excerpt(record, field),
        categories: [], scores: {}, context: { "flagged_by_id" => by&.id, "note" => note }.compact
      )
    end

    def self.audit_filed_for_review(flag, by:, note:)
      payload = {
        flag_id: flag.id, flaggable_type: flag.flaggable_type, flaggable_id: flag.flaggable_id,
        field: flag.field, note: note,
        summary: "Flag ##{flag.id} filed by hand on #{flag.flaggable_label} · #{flag.field_label}"
      }
      Moderate.audit(:flag_filed, subject: flag, actor: by, payload: payload.compact)
    end

    # What the reviewer reads in the queue: the record's evidence snapshot for the
    # field (the same text a report would freeze), else the field's own text.
    def self.review_excerpt(record, field)
      text = record.moderation_snapshot(field) if record.respond_to?(:moderation_snapshot)
      text = record.public_send(field) if text.nil? && record.respond_to?(field)
      text.to_s.truncate(500) if text.is_a?(String) && text.present?
    end
    private_class_method :file_for_review!, :audit_filed_for_review, :review_excerpt

    def self.sources
      (SOURCES + Moderate.config.adapters.keys.map(&:to_s)).uniq
    end

    def pending?
      status == "pending"
    end

    def closed?
      status.in?(%w[actioned dismissed])
    end

    # Close this flag as ACTIONED — someone (or an automated policy) took
    # action on the flagged content. Sugar over Moderate::Services::ResolveFlag
    # (row lock, re-check, audit), mirroring Report#resolve!/#dismiss!.
    # `by:` is the reviewing user when a human decided; leave it nil for
    # automated closes — recording a human who never looked would poison the
    # audit trail (DSA statements of reasons read these rows).
    #
    # Enforce from the flag itself — the bridge every host used to hand-write:
    #
    #   flag.action!(by: admin, note: "Slur", remove_content: true)
    #   flag.action!(by: admin, note: "Repeat offender", ban_user: true)
    #
    # Either option escalates to a report (the open one on the same content and
    # field, or a system one) and resolves it, so the content is removed through
    # the reportable's `remove_reported_field!`, the ban through your `ban_handler`,
    # and the affected user gets the statement of reasons and the appeal window a
    # restriction requires. `flag.report` is that report afterwards.
    def action!(note:, by: nil, **enforcement)
      Moderate::Services::ResolveFlag.new(self, by: by).action!(note: note, **enforcement)
    end

    # The queue-wide verb: Report#resolve! and Flag#resolve! take the same
    # keywords, so one admin action (Moderate::Moderation#resolve) decides both.
    alias resolve! action!

    # Close this flag with NO action taken. The canonical automated use is
    # SUPERSEDED content: when the flagged field changes (text edited, photo
    # replaced/reverted), a still-pending flag is about content that is no
    # longer live — leaving it pending keeps `flagged?` true and mislabels
    # the NEW content in any host UI keyed on it. Hosts should dismiss with a
    # note saying what superseded it.
    def dismiss!(note:, by: nil)
      Moderate::Services::ResolveFlag.new(self, by: by).dismiss!(note: note)
    end

    # The report an enforcing `action!` went through, or nil (a triage-only close,
    # or a flag still pending).
    def report
      report_id = context.to_h["report_id"]
      Moderate::Report.find_by(id: report_id) if report_id.present?
    end

    # A label for the flagged thing in the queue. Asks the flaggable for its own
    # `moderation_label` (Moderate::Reportable interface); falls back to a generic
    # "Type id" string for content that doesn't implement it.
    def flaggable_label
      return flaggable.moderation_label if flaggable.respond_to?(:moderation_label)

      "#{flaggable_type} #{flaggable_id}"
    end

    # What humans call the flagged field ("Chat message", not "body"). Same
    # resolution as Report#reported_field_label, so a queue that lists reports and
    # flags side by side names a field the same way in both. Works after the
    # flagged record is gone (falls back to `flaggable_type`).
    def field_label
      Moderate.reportable_field_label(flaggable || flaggable_type, field)
    end

    private

    # See the before_save comment: keep the NOT-NULL JSON columns non-null on MySQL.
    def default_json_columns
      self.categories ||= []
      self.scores ||= {}
      self.context ||= {}
    end

    def notify_content_flagged
      # `content_flagged` has NO user recipient by design — it's an admin/system
      # signal, not a message to the content owner — so the Event's recipients stay
      # empty and the host's notify hook routes it to admin channels only.
      Moderate.notify(
        :content_flagged,
        subject: self,
        payload: {
          flaggable_type: flaggable_type,
          flaggable_id: flaggable_id,
          field: field,
          field_label: field_label,
          source: source,
          categories: Array(categories),
          summary: "content flagged (#{source}) on #{flaggable_label} · #{field_label}"
        }
      )
    end
  end
end
