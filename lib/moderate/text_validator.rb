# frozen_string_literal: true

module ActiveModel
  module Validations
    class ModerateValidator < EachValidator
      def validate_each(record, attribute, value)
        return if value.blank?

        begin
          text = value.to_s
          return if text.nil?

          if Moderate::Text.bad_words?(text)
            record.errors.add(attribute, options[:message] || Moderate.configuration.error_message)
          end
        rescue Moderate::Error => e
          Rails.logger.error "Moderate validation error: #{e.message}"
          record.errors.add(attribute, "Moderation check failed: #{e.message}")
        rescue StandardError => e
          Rails.logger.error "Unexpected error in moderate validation: #{e.message}"
          record.errors.add(attribute, "Moderation check failed")
        end
      end
    end

  end
end
