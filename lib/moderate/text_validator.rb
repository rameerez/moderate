# frozen_string_literal: true

require "active_model"

module ActiveModel
  module Validations
    # `validates :body, moderate: true` — the 0.x one-liner, kept for compatibility.
    # It is the same check as `moderates :body, with: :wordlist, mode: :block`: the
    # built-in offline :wordlist classifies the value, and an objectionable one adds
    # the same `:objectionable_content` error (or your `message:`). No other filter
    # policy applies to the field through it.
    #
    # Required by Moderate::Engine (it reopens ActiveModel::Validations, so Zeitwerk
    # doesn't manage it).
    class ModerateValidator < EachValidator
      def validate_each(record, attribute, value)
        return if value.blank?

        policy = Moderate::Configuration::FilterPolicy.new(
          class_name: record.class.name, field: attribute.to_s, adapter: :wordlist, mode: :block
        )
        return unless Moderate.classify(value, policy: policy).flagged?

        record.errors.add(attribute, options[:message] || :objectionable_content)
      end
    end
  end
end
