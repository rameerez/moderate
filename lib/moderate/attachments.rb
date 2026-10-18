# frozen_string_literal: true

module Moderate
  # What the filter and ClassifyJob need to know about an Active Storage value
  # before they hand it to an adapter: which blobs are behind it, whether every one
  # of them is on its storage service, and whether this record's field was already
  # classified for exactly those blobs.
  #
  # The "already classified" marker lives on the blob itself
  # (`blob.metadata["moderate_classified"]["<Class>/<id>/<field>"]`), so it survives
  # across processes: a field is classified once per set of blobs whichever of the
  # inline classification, the immediate job or the after-upload guard job gets there
  # first; the others find the marker and stop.
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

    def classified?(record, field, value)
      found = blobs(value)
      key = marker_key(record, field)
      found.any? && found.all? { |blob| blob.reload.metadata.to_h.dig(MARKER, key).present? }
    end

    def mark_classified!(record, field, value, at: Time.current)
      key = marker_key(record, field)
      blobs(value).each do |blob|
        metadata = blob.reload.metadata.to_h
        markers = metadata.fetch(MARKER, {}).merge(key => at.iso8601)
        blob.update_column(:metadata, metadata.merge(MARKER => markers))
      end
    end

    def marker_key(record, field)
      "#{record.class.name}/#{record.id}/#{field}"
    end
  end
end
