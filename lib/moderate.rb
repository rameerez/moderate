# frozen_string_literal: true

require_relative "moderate/version"
require_relative "moderate/text"
require_relative "moderate/text_validator"
require_relative "moderate/word_list"

module Moderate
  class Error < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configuration=(config)
      @configuration = config
    end

    def configure
      yield(configuration)
    end
  end

  class Configuration
    ACCESSORS = %i[
      error_message additional_words excluded_words blacklist_regexp_pattern whitelist_regexp_pattern
    ].freeze

    attr_accessor(*ACCESSORS)

    def initialize
      @error_message = "contains moderatable content (bad words)"
      @additional_words = []
      @excluded_words = []
      @blacklist_regexp_pattern = nil
      @whitelist_regexp_pattern = nil
    end
  end
end
