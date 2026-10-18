# frozen_string_literal: true

module Moderate
  # What the filter and ClassifyJob need to know about an Active Storage value
  # before they hand it to an adapter, and the claim protocol that makes each set of
  # files classified once per record without holding a lock during the adapter call.
  #
  # ── Claim, classify, complete ───────────────────────────────────────────────
  # `classify_once` runs in three steps:
  #
  #   1. under the CONTENT record's row lock (content first, like every lock in the
  #      gem): stop if this record's field is already classified for exactly these
  #      files, or if another worker holds a live claim on them; else write our
  #      claim (a moderate_classifications row) and release the lock;
  #   2. call the adapter, outside any lock — a slow provider never blocks writes to
  #      the content's row (a user's, for an avatar);
  #   3. under the lock again: if the field still holds the same files and the claim
  #      is still ours, file the flag, stamp the row classified and clear the
  #      claim; otherwise discard the result (the files changed — the new set has
  #      its own classification — or our claim expired and another worker took it).
  #
  # A claim expires after `config.classification_claim_ttl` (10 minutes by default),
  # so a worker that died mid-call doesn't block the files forever: the next look
  # after expiry overrides it.
  #
  # ── Where the claims live ──────────────────────────────────────────────────────
  # In the gem's own table, `moderate_classifications` (Moderate::Classification):
  # one row per record, field and exact set of files (a digest of their ordered blob
  # ids), UNIQUE on those four, holding the claim (`claimed_by`, `claimed_at`) and
  # the completion (`classified_at`). Rows are written only under the content
  # record's lock, so nothing else — another record sharing the blob, Active
  # Storage's analyzer rewriting `blob.metadata` — can touch them. The same files on
  # another record, or a changed set on this one, are a different row: classified
  # again.
  #
  # @api private
  module Attachments
    module_function

    def attachment?(value)
      value.respond_to?(:attached?) && defined?(::ActiveStorage::Blob) ? true : false
    end

    def blobs(value)
      return [] unless attachment?(value)

      found = value.respond_to?(:blobs) ? value.blobs.to_a : [value.try(:blob)]
      found.grep(::ActiveStorage::Blob).sort_by(&:id)
    end

    def blob_ids(value)
      blobs(value).map(&:id)
    end

    # Every file behind the value is on its service (a value with no blobs, or one
    # that isn't an attachment at all, has nothing to wait for).
    def uploaded?(value)
      blobs(value).all? { |blob| blob.service.exist?(blob.key) }
    end

    # A stored blob whose file isn't on its service: a direct upload still in flight.
    # A blob this save is about to upload (not persisted yet) has its bytes in hand.
    def upload_unfinished?(value)
      blobs(value).any? { |blob| blob.persisted? && !blob.service.exist?(blob.key) }
    end

    def classified?(record, field, value)
      found = blobs(value)
      found.any? && Classification.for_set(record, field, digest(found)).where.not(classified_at: nil).exists?
    end

    # The whole protocol (see the module comment). `read` returns the field's value
    # as committed now (it is called under the lock, twice); `classify` calls the
    # adapter; `file` files the flag for a flagged result. Returns one of:
    #   :classified   — classified by us, marked
    #   :done         — already classified for these files
    #   :claimed      — another worker holds a live claim (with its expiry, see #claim_expires_at)
    #   :discarded    — the files changed, or the claim was lost, while the adapter ran
    #   :empty        — nothing attached any more
    def classify_once(record, field, owner:, read:, classify:, file:, now: Time.current)
      claim = Moderate.with_row_lock(record) { claim!(record, field, read.call, owner: owner, now: now) }
      return claim[:status] unless claim[:status] == :claimed_by_us

      result = classify.call(claim[:value])

      Moderate.with_row_lock(record) do
        value = read.call
        found = blobs(value)
        row = Classification.find_by(id: claim[:row].id)
        if row && found.map(&:id) == claim[:blob_ids] && row.claimed_by == owner
          file.call(value, result) if result.flagged?
          row.update!(classified_at: Time.current, claimed_by: nil, claimed_at: nil,
            adapter: result.source.to_s.presence, flagged: result.flagged?)
          :classified
        else
          Classification.where(id: claim[:row].id, claimed_by: owner).update_all(claimed_by: nil, claimed_at: nil)
          :discarded
        end
      end
    end

    # When a live claim held by someone else expires (nil if there isn't one).
    def claim_expires_at(record, field, value)
      found = blobs(value)
      claimed_at = found.any? && Classification.for_set(record, field, digest(found)).pick(:claimed_at)
      claimed_at && (claimed_at + claim_ttl)
    end

    def claim_ttl
      Moderate.config.classification_claim_ttl.to_i
    end

    def digest(found)
      Digest::SHA256.hexdigest(found.map(&:id).sort.join(","))[0, 16]
    end

    # --- Under the lock ------------------------------------------------------------

    def claim!(record, field, value, owner:, now:)
      found = blobs(value)
      return { status: :empty } if found.empty?

      row = Classification.for_set(record, field, digest(found)).first_or_initialize
      return { status: :done } if row.classified?
      return { status: :claimed } if row.claimed_by.present? && row.claimed_by != owner && row.claimed_at > now - claim_ttl

      row.update!(claimed_by: owner, claimed_at: now)
      { status: :claimed_by_us, row: row, blob_ids: found.map(&:id), value: value }
    rescue ActiveRecord::RecordNotUnique
      { status: :claimed } # another worker inserted the row first (only without row locks)
    end
  end
end
