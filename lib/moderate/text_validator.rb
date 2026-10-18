# frozen_string_literal: true

module ActiveModel
  module Validations
    # `validates :field, moderate: true` — the 0.x validator, kept for compatibility.
    class ModerateValidator < EachValidator
      def validate_each(record, attribute, value)
        return if value.blank?

        begin
          text = value.to_s
          return if text.nil?

          record.errors.add(attribute, options[:message] || Moderate.configuration.error_message) if Moderate::Text.bad_words?(text)
        rescue Moderate::Error => error
          Rails.logger.error "Moderate validation error: #{error.message}"
          record.errors.add(attribute, "Moderation check failed: #{error.message}")
        rescue StandardError => error
          Rails.logger.error "Unexpected error in moderate validation: #{error.message}"
          record.errors.add(attribute, "Moderation check failed")
        end
      end
    end
  end
end
