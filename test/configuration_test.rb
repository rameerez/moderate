# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  class CountingAdapter
    class << self
      attr_accessor :instances
    end
    self.instances = 0

    def initialize
      self.class.instances += 1
    end

    def classify(_value)
      Moderate::Result.allowed(source: "counting")
    end
  end

  test "class adapter registrations are instantiated once and memoized" do
    CountingAdapter.instances = 0
    Moderate.config.register_adapter :counting, CountingAdapter

    first = Moderate.config.adapter_for(:counting)
    second = Moderate.config.adapter_for(:counting)

    assert_same first, second
    assert_equal 1, CountingAdapter.instances
  end

  test "classification_claim_ttl is capped at a day and must be positive, with a clear error" do
    Moderate.configure { |config| config.classification_claim_ttl = 1.day }
    assert_equal 1.day, Moderate.config.classification_claim_ttl

    [2.days, 0, -5, nil].each do |ttl|
      error = assert_raises(ArgumentError, ttl.inspect) { Moderate.configure { |config| config.classification_claim_ttl = ttl } }
      assert_match "at most a day", error.message
    end
  end
end
