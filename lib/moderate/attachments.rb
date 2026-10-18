# frozen_string_literal: true

module Moderate
  # What the filter and ClassifyJob need to know about an Active Storage value
  # before they hand it to an adapter: which blobs are behind it, whether every one
  # of them is on its storage service, and whether this record's field was already
  # classified for exactly those blobs.
  #
  # The "already classified" marker lives on the blobs themselves
  # (`blob.metadata["moderate_classified"]["<Class>/<id>/<field>/<set digest>"]`), so
  # it survives across processes. The key names the record, the field and the exact
  # set of blobs (a digest of their ordered ids): the same files on another record,
  # or a changed set on this one (a file added or removed), are classified again.
  #
  # Callers check and write it under the CONTENT record's row lock (the inline path
  # and ClassifyJob both do, content first like every other lock in the gem), so the
  # immediate job and the guard can't both classify. The write re-reads the blob's
  # metadata and merges into it, keeping Active Storage's analyzer keys. The analyzer
  # writes the same column without our lock, so in a rare race its write can drop
  # our marker; the set is then classified once more, which files no second flag
  # (beta4 allows one pending flag per content and field).
  #
  # @api private
  module Attachments
    MARKER = "moderate_classified"

    module_function

    def attachment?(value)
      value.respond_to?(:attached?) && defined?(::ActiveStorage::Blob) ? true : false
    end

    def blobs(value)
      return [] unless attachment?(value)

      found = value.respond_to?(:blobs) ? value.blobs.to_a : [value.try(:blob)]
      found.grep(::ActiveStorage::Blob)
    end

    def blob_ids(value)
      blobs(value).map(&:id).sort
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
      found.any? && found.all? { |blob| blob.reload.metadata.to_h.dig(MARKER, key).present? }
    end

    def mark_classified!(record, field, value, at: Time.current)
      found = blobs(value)
      key = marker_key(record, field, found)
      found.each do |blob|
        metadata = blob.reload.metadata.to_h
        markers = metadata.fetch(MARKER, {}).merge(key => at.iso8601)
        blob.update_column(:metadata, metadata.merge(MARKER => markers))
      end
    end

    def marker_key(record, field, found)
      digest = Digest::SHA256.hexdigest(found.map(&:id).sort.join(","))[0, 16]
      "#{record.class.name}/#{record.id}/#{field}/#{digest}"
    end
  end
end
