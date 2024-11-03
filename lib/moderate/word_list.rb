# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'tmpdir'
require 'logger'

module Moderate
  class WordList
    WORD_LIST_URL = 'https://raw.githubusercontent.com/coffee-and-fun/google-profanity-words/main/data/en.txt'
    CACHE_TTL = 30 * 24 * 60 * 60 # 30 days in seconds

    class << self
      def load
        cache_path = cache_file_path

        begin
          if File.exist?(cache_path)
            if cache_valid?(cache_path)
              words = File.read(cache_path, encoding: 'UTF-8').split("\n").to_set
              return words unless words.empty?
            else
              logger.info("[moderate gem] Cache expired (older than #{CACHE_TTL / 86400} days). Refreshing word list...")
              return download_and_cache(cache_path)
            end
          end

          logger.info("[moderate gem] No cache found. Downloading word list for the first time...")
          download_and_cache(cache_path)
        rescue StandardError => e
          logger.error("[moderate gem] Error loading word list: #{e.message}")
          logger.debug("[moderate gem] #{e.backtrace.join("\n")}")
          raise Moderate::Error, "Failed to load bad words list: #{e.message}"
        end
      end

      def refresh_word_list!
        logger.info("[moderate gem] Manually refreshing word list")
        cache_path = cache_file_path
        File.delete(cache_path) if File.exist?(cache_path)
        download_and_cache(cache_path)
      end

      private

      def cache_valid?(cache_path)
        return false unless File.exist?(cache_path)

        cache_age = Time.now - File.mtime(cache_path)
        cache_age <= CACHE_TTL
      end

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

        logger.info("[moderate gem] Successfully downloaded and cached #{words.size} words to #{cache_path}")
        logger.info("[moderate gem] Next cache refresh will occur after: #{Time.now + CACHE_TTL}")

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
