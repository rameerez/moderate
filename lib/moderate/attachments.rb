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
  #      claim {owner, claimed_at} and release the lock;
  #   2. call the adapter, outside any lock — a slow provider never blocks writes to
  #      the content's row (a user's, for an avatar);
  #   3. under the lock again: if the field still holds the same files and the claim
  #      is still ours, file the flag, write the classified marker and clear the
  #      claim; otherwise discard the result (the files changed — the new set has
  #      its own classification — or our claim expired and another worker took it).
  #
  # A claim expires after `config.classification_claim_ttl` (10 minutes by default),
  # so a worker that died mid-call doesn't block the files forever: the next look
  # after expiry overrides it.
  #
  # ── Where the marks live ──────────────────────────────────────────────────────
  # On the blobs themselves, merged into `blob.metadata`:
  # `["moderate_classified"][key]` (when classified) and `["moderate_claims"][key]`
  # ({owner, claimed_at}). The key names the record, the field and the exact set of
  # files (a digest of their ordered blob ids): the same files on another record, or
  # a changed set on this one (a file added or removed), are classified again. Every
  # write re-reads the blob's metadata and merges into it, keeping Active Storage's
  # analyzer keys. The analyzer writes that column without our lock, so in a rare
  # race its write can drop one of our marks; the set is then classified once more,
  # which files no second pending flag (beta4 allows one per content and field).
  #
  # @api private
  module Attachments
    MARKER = "moderate_classified"
    CLAIMS = "moderate_claims"

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
      key = marker_key(record, field, found)
      found.any? && found.all? { |blob| metadata(blob).dig(MARKER, key).present? }
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
        if found.map(&:id) == claim[:blob_ids] && claim_owner(found, claim[:key]) == owner
          file.call(value, result) if result.flagged?
          complete!(found, claim[:key])
          :classified
        else
          release!(claim[:blob_ids], claim[:key], owner)
          :discarded
        end
      end
    end

    # When a live claim held by someone else expires (nil if there isn't one).
    def claim_expires_at(record, field, value)
      found = blobs(value)
      claim = found.first && metadata(found.first).dig(CLAIMS, marker_key(record, field, found))
      claim && (Time.iso8601(claim["claimed_at"]) + claim_ttl)
    end

    def claim_ttl
      Moderate.config.classification_claim_ttl.to_i
    end

    def marker_key(record, field, found)
      digest = Digest::SHA256.hexdigest(found.map(&:id).sort.join(","))[0, 16]
      "#{record.class.name}/#{record.id}/#{field}/#{digest}"
    end

    # --- Under the lock ------------------------------------------------------------

    def claim!(record, field, value, owner:, now:)
      found = blobs(value)
      return { status: :empty } if found.empty?

      key = marker_key(record, field, found)
      return { status: :done } if found.all? { |blob| metadata(blob).dig(MARKER, key).present? }

      current = metadata(found.first).dig(CLAIMS, key)
      return { status: :claimed } if current && current["owner"] != owner && Time.iso8601(current["claimed_at"]) > now - claim_ttl

      found.each { |blob| write(blob) { |meta| (meta[CLAIMS] ||= {})[key] = { "owner" => owner, "claimed_at" => now.iso8601 } } }
      { status: :claimed_by_us, key: key, blob_ids: found.map(&:id), value: value }
    end

    def claim_owner(found, key)
      found.first && metadata(found.first).dig(CLAIMS, key, "owner")
    end

    def complete!(found, key, at: Time.current)
      found.each do |blob|
        write(blob) do |meta|
          (meta[MARKER] ||= {})[key] = at.iso8601
          meta[CLAIMS]&.delete(key)
          meta.delete(CLAIMS) if meta[CLAIMS].blank?
        end
      end
    end

    # Drop our claim from the files we claimed (some may be gone already).
    def release!(blob_ids, key, owner)
      ::ActiveStorage::Blob.where(id: blob_ids).find_each do |blob|
        next unless metadata(blob).dig(CLAIMS, key, "owner") == owner

        write(blob) do |meta|
          meta[CLAIMS].delete(key)
          meta.delete(CLAIMS) if meta[CLAIMS].blank?
        end
      end
    end

    def metadata(blob)
      blob.reload.metadata.to_h.deep_dup
    end

    # Re-read, change, write back: Active Storage's own keys are kept.
    def write(blob)
      meta = metadata(blob)
      yield meta
      blob.update_column(:metadata, meta)
    end
  end
end
