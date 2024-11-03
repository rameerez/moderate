# frozen_string_literal: true

module Moderate
  class Text
    class << self
      def bad_words?(text)
        return false if text.blank?

        @words_set ||= Set.new(compute_word_list)
        text.downcase.split(/\W+/).any? { |word| @words_set.include?(word) }
      end

      private

      DEFAULT_BAD_WORDS = Set.new(["asdf"]).freeze

      def compute_word_list
        (DEFAULT_BAD_WORDS + Moderate.configuration.additional_words -
         Moderate.configuration.excluded_words).to_set
      end

      def reset_word_list!
        @words_set = nil
      end
    end
  end
end
