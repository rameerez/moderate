# frozen_string_literal: true

module Moderate
  # One record's field, for one exact set of attached files (`digest`, of the ordered
  # blob ids): who is classifying it right now (`claimed_by`, `claimed_at`) and when
  # it was classified (`classified_at`, with the adapter and whether it flagged).
  # The claim protocol that writes it lives in Moderate::Attachments; rows hold ids,
  # a digest and timestamps, no content, and Moderate.purge deletes old ones.
  #
  # @api private
  class Classification < ApplicationRecord
    self.table_name = "moderate_classifications"

    belongs_to :record, polymorphic: true, optional: true

    scope :for_set, lambda { |record, field, digest|
      where(record_type: record.class.polymorphic_name, record_id: record.id, field: field.to_s, digest: digest)
    }

    def classified?
      classified_at.present?
    end
  end
end
