# frozen_string_literal: true

module Moderate
  class Text
    class << self
      def bad_words?(text)
        return false if text.blank?

        return true if match_regexp_pattern?(text)

        @words_set ||= Set.new(compute_word_list)
        text.downcase.split(/\W+/).any? { |word| @words_set.include?(word) }
      end

      private

      def compute_word_list
        @default_words ||= begin
          words = WordList.load
          logger.info("[moderate gem] Loaded #{words.size} words from word list")
          words
        end

        result = (@default_words + configuration.additional_words -
                 configuration.excluded_words).to_set
        logger.debug("[moderate gem] Final word list size: #{result.size}")
        result
      end

      def reset_word_list!
        @words_set = nil
        @default_words = nil
      end

      def logger
        @logger ||= defined?(Rails) ? Rails.logger : Logger.new($stdout)
      end

      def configuration
        @configuration ||= Moderate.configuration
      end

      def match_regexp_pattern?(text)
        configuration.regexp_pattern.is_a?(Regexp) && configuration.regexp_pattern.match?(text)
      end
    end
  end
end
