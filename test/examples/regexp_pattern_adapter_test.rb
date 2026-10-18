# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/regexp_pattern_adapter"

# The reference regexp adapter (examples/regexp_pattern_adapter.rb, after PR #1):
# it honors the adapter contract and drives a filter like any adapter.
class RegexpPatternAdapterTest < ActiveSupport::TestCase
  ADAPTER = RegexpPatternAdapter.new(spam: [%r{https?://\S+}i], privacy: /\b\d{3}[\s.-]?\d{3}[\s.-]?\d{3}\b/)

  test "clean text is allowed" do
    result = ADAPTER.classify("see you on the ladder")

    assert_predicate result, :allowed?
    assert_empty result.labels
  end

  test "a match flags under its category and says what matched" do
    result = ADAPTER.classify("call me 600 123 456 or see https://example.com/x")

    assert_predicate result, :flagged?
    assert_equal %i[spam privacy], result.categories
    assert_equal({ spam: ["https://example.com/x"], privacy: ["600 123 456"] }, result.raw[:matches])
  end

  test "only Regexp patterns are accepted" do
    assert_raises(ArgumentError) { RegexpPatternAdapter.new(spam: "http") }
  end

  test "it blocks a save, being synchronous" do
    Moderate.configure do |config|
      config.register_adapter :patterns, ADAPTER
      config.filter "Comment", :body, with: :patterns, mode: :block
    end

    comment = Comment.new(user: User.create!(name: "U"), body: "buy at https://spam.example")

    assert_not comment.valid?
    assert_predicate comment.errors[:body], :any?
  end
end
