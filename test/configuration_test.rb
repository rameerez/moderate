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
end
