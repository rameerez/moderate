# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'tmpdir'
require 'logger'

module Moderate
  class WordList
    WORD_LIST_URL = 'https://raw.githubusercontent.com/coffee-and-fun/google-profanity-words/main/data/en.txt'

    class << self
      def load
        cache_path = cache_file_path

        begin
          if File.exist?(cache_path)
            words = File.read(cache_path, encoding: 'UTF-8').split("\n").to_set
            return words unless words.empty?
          end

          download_and_cache(cache_path)
        rescue StandardError => e
          logger.error("[moderate gem] Error loading word list: #{e.message}")
          logger.debug("[moderate gem] #{e.backtrace.join("\n")}")
          raise Moderate::Error, "Failed to load bad words list: #{e.message}"
        end
      end

      private

      def cache_file_path
        if defined?(Rails)
          Rails.root.join('tmp', 'moderate_bad_words.txt')
        else
          File.join(Dir.tmpdir, 'moderate_bad_words.txt')
        end
      end

      def download_and_cache(cache_path)
        uri = URI(WORD_LIST_URL)
        response = Net::HTTP.get_response(uri)

        unless response.is_a?(Net::HTTPSuccess)
          raise Moderate::Error, "Failed to download word list. HTTP Status: #{response.code}"
        end

        content = response.body.force_encoding('UTF-8')
        words = content.split("\n").map(&:strip).reject(&:empty?).to_set

        if words.empty?
          raise Moderate::Error, "Downloaded word list is empty"
        end

        logger.info("[moderate gem] Downloaded #{words.size} words from #{WORD_LIST_URL}")
        File.write(cache_path, content, encoding: 'UTF-8')
        logger.debug("[moderate gem] Cached word list to: #{cache_path}")

        words
      end

      def logger
        @logger ||= defined?(Rails) ? Rails.logger : Logger.new($stdout)
      end
    end
  end
end
