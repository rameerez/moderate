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
    validates :source, inclusion: { in: ->(_flag) { sources } }
    validates :mode, inclusion: { in: MODES }
    validates :resolution_note, presence: true, if: :closed?

    # The single entry point the Filterable concern uses to file a flag. Centralizes
    # coercion (categories → Array, scores/context → Hash) so callers can hand us
    # whatever shape a Moderate::Result exposed without each one re-normalizing.
    # `context` is freeform JSON for audit (which policy fired, the raw classifier
    # payload, etc.) — never relied on by the gem's own logic.
    def self.flag!(flaggable:, field:, owner:, source:, mode:, excerpt:, categories:, scores:, context:)
      create!(
        flaggable: flaggable,
        field: field,
        owner: owner,
        source: source,
        mode: mode,
        excerpt: excerpt,
        categories: Array(categories),
        scores: scores.to_h,
        context: context.to_h
      )
    end

    def self.sources
      (SOURCES + Moderate.config.adapters.keys.map(&:to_s)).uniq
    end

    def pending?
      status == "pending"
    end

    def closed?
      status.in?(%w[actioned dismissed])
    end

    # A label for the flagged thing in the queue. Asks the flaggable for its own
    # `moderation_label` (Moderate::Reportable interface); falls back to a generic
    # "Type id" string for content that doesn't implement it.
    def flaggable_label
      return flaggable.moderation_label if flaggable.respond_to?(:moderation_label)

      "#{flaggable_type} #{flaggable_id}"
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
          source: source,
          categories: Array(categories),
          summary: "content flagged (#{source}) on #{flaggable_label}##{field}"
        }
      )
    end
  end
end
