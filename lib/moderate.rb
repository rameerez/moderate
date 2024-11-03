# frozen_string_literal: true

require_relative "moderate/version"
require_relative "moderate/text"
require_relative "moderate/text_validator"

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
    attr_accessor :error_message, :additional_words, :excluded_words

    def initialize
      @error_message = "contains moderatable content (bad words)"
      @additional_words = []
      @excluded_words = []
    end
  end
end
