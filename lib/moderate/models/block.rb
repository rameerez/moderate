# frozen_string_literal: true

module Moderate
  # The bidirectional safety edge between two users — the table behind every
  # "block" feature and behind `Moderate.blocked_ids_for`.
  #
  # A block is DIRECTED in the data (`blocker` → `blocked`) but BIDIRECTIONAL in
  # effect: once either side blocks, neither should see or reach the other. That
  # asymmetry-in-storage / symmetry-in-meaning is the whole subtlety of blocking,
  # and it lives in exactly one place — the `related_user_ids` SSOT query below —
  # so search, messaging, profiles, and feeds never hand-roll their own block SQL
  # (and never get the direction half-right, which is the classic blocking bug).
  #
  # Apple Guideline 1.2(c) and Google Play's UGC policy both require an in-app way
  # to block abusive users; this model is the mechanism.
  # Apple:  https://developer.apple.com/app-store/review/guidelines/#user-generated-content
  # Google: https://support.google.com/googleplay/android-developer/answer/9876937
  class Block < ApplicationRecord
    self.table_name = "moderate_blocks"

    # Both ends resolve to the host's configured user class (read lazily as a String
    # from config, same pattern as every other actor association in the gem). NOT
    # optional: a block edge with a missing end is meaningless.
    belongs_to :blocker, class_name: Moderate.config.user_class
    belongs_to :blocked, class_name: Moderate.config.user_class

    # A user can block another user at most once. The DB also enforces this with a
    # unique index (`index_moderate_blocks_on_blocker_id_and_blocked_id`); the model
    # validation gives a friendly error instead of a raw RecordNotUnique, and the
    # `block!` entrypoint uses find_or_initialize to stay idempotent regardless.
    validates :blocked_id, uniqueness: { scope: :blocker_id }
    validate :cannot_block_self

    scope :recent_first, -> { order(created_at: :desc) }

    # Find the edge between two users in EITHER direction (used to answer
    # "blocked_with?" — is there a block between us, regardless of who blocked whom).
    scope :between, ->(user_a, user_b) {
      return none if user_a.blank? || user_b.blank?

      where(blocker_id: user_a.id, blocked_id: user_b.id)
        .or(where(blocker_id: user_b.id, blocked_id: user_a.id))
    }

    # Idempotent block. Creating the same edge twice is a no-op that returns the
    # existing record, so callers never have to check first. Everything runs in one
    # transaction so the audit entry and the on_block side effect commit atomically
    # with the row; the notify fires AFTER the transaction so a slow/failing mailer
    # can't roll back the block itself.
    #
    # On a real (new) block we:
    #   1. fire the host's `on_block` side-effect hook (e.g. tear down a pending
    #      invite, leave a shared room) — host-defined, no-op by default;
    #   2. audit "block created" with both ids;
    #   3. notify `:user_blocked`.
    # Re-blocking an existing edge skips all three (nothing actually changed).
    def self.block!(blocker:, blocked:)
      raise ArgumentError, "blocker is required" if blocker.blank?
      raise ArgumentError, "blocked is required" if blocked.blank?

      # Self-block is a NO-OP, not an exception. Blocking yourself is meaningless, and
      # a UI that wires a generic "block this user" affordance shouldn't have to guard
      # the degenerate "block myself" case — so we return an UNPERSISTED, invalid
      # record (carrying the `cannot_block_self` validation error for inspection)
      # rather than raising. No row is written, no on_block/audit/notify fires. (The
      # DB CHECK constraint `moderate_blocks_no_self_block` is the belt-and-suspenders
      # backstop if a caller bypasses this path.)
      if blocker.id.present? && blocker.id == blocked.id
        block = new(blocker: blocker, blocked: blocked)
        block.valid? # populate errors[:blocked] with the self-block message
        return block
      end

      block = nil
      created = false

      transaction do
        block = find_or_initialize_by(blocker: blocker, blocked: blocked)
        created = block.new_record?
        block.save! if created

        if created
          # Side-effect hook FIRST, inside the transaction: if the host's on_block
          # raises, the whole block rolls back rather than leaving a half-applied
          # state (edge saved but invite not torn down).
          on_block_payload = audit_payload_from_on_block(
            Moderate.run_on_block(blocker: blocker, blocked: blocked, at: block.created_at)
          )

          Moderate.audit(
            name: :user_blocked,
            subject: block,
            actor: blocker,
            payload: on_block_payload.merge(
              blocker_id: blocker.id,
              blocked_id: blocked.id,
              summary: "user #{blocker.id} blocked user #{blocked.id}"
            )
          )
        end
      end

      # Notify outside the transaction (see class doc): notify must never be able to
      # roll back the action it's announcing.
      if created
        Moderate.notify(
          :user_blocked,
          subject: block,
          actor: blocker,
          payload: { blocker_id: blocker.id, blocked_id: blocked.id, summary: "user #{blocker.id} blocked user #{blocked.id}" }
        )
      end

      block
    end

    # Remove a block. Returns false if there was nothing to remove (already
    # unblocked), true otherwise — so it's safe to call unconditionally.
    def self.unblock!(blocker:, blocked:)
      block = find_by(blocker: blocker, blocked: blocked)
      return false if block.blank?

      transaction do
        block.destroy!
        Moderate.audit(
          name: :user_unblocked,
          subject: block,
          actor: blocker,
          payload: {
            blocker_id: blocker.id,
            blocked_id: blocked.id,
            summary: "user #{blocker.id} unblocked user #{blocked.id}"
          }
        )
      end

      Moderate.notify(
        :user_unblocked,
        subject: block,
        actor: blocker,
        payload: { blocker_id: blocker.id, blocked_id: blocked.id, summary: "user #{blocker.id} unblocked user #{blocked.id}" }
      )

      true
    end

    # THE source of truth for "everyone this user is on a block edge with" — both
    # the people they blocked AND the people who blocked them (bidirectional). This
    # is what `Moderate.blocked_ids_for` delegates to, and what hosts use to hide
    # blocked pairs from each other everywhere:
    #
    #   Post.where.not(user_id: Moderate.blocked_ids_for(current_user))  # via the facade
    #
    # Returns an AR relation of user ids (NOT a loaded array) so callers can compose
    # it into a `where.not(user_id: ...)` subquery that runs entirely in the database
    # — no N user ids round-tripped into Ruby just to be sent back as a giant IN list.
    #
    # The UNION is the cleanest portable way to express "blocked_id where I'm the
    # blocker, OR blocker_id where I'm the blocked" as a single id set; we build it
    # against the model's OWN `quoted_table_name` (not a hard-coded "moderate_blocks")
    # so a host that renames/prefixes the table still gets correct SQL.
    def self.related_user_ids(user)
      user_model = Moderate.user_class
      return user_model.none.select(:id) if user.blank?

      user_table = user_model.quoted_table_name
      user_primary_key = connection.quote_column_name(user_model.primary_key)
      block_table = quoted_table_name

      user_model
        .where(
          "#{user_table}.#{user_primary_key} IN (
            SELECT blocked_id FROM #{block_table} WHERE blocker_id = :user_id
            UNION
            SELECT blocker_id FROM #{block_table} WHERE blocked_id = :user_id
          )",
          user_id: user.id
        )
        .select(:id)
    end

    private

    def self.audit_payload_from_on_block(result)
      return {} if result.nil?
      return result if result.is_a?(Hash)
      return result.to_h if result.respond_to?(:to_h)

      {}
    rescue ArgumentError, TypeError
      {}
    end
    private_class_method :audit_payload_from_on_block

    # The DB has a CHECK constraint (`moderate_blocks_no_self_block`) too; this gives
    # the friendly validation error before the row ever reaches the database.
    def cannot_block_self
      return if blocker_id.blank? || blocked_id.blank? || blocker_id != blocked_id

      errors.add(:blocked, I18n.t("moderate.errors.cannot_block_self", default: "You can't block yourself"))
    end
  end
end
