# frozen_string_literal: true

require "test_helper"

# `validates :field, moderate: true`, the 0.x one-liner, and the copy a rejected
# field shows. README "Upgrading from 0.x" promises the validator is the :wordlist
# adapter in :block mode.
class LegacyValidatorTest < ActiveSupport::TestCase
  OBJECTIONABLE = "you are a bitch"

  class Note
    include ActiveModel::Validations

    attr_accessor :body, :title

    validates :body, moderate: true
    validates :title, moderate: { message: "keep it clean" }

    def self.name = "Note"
  end

  def note(body: "hello", title: "hi")
    Note.new.tap do |record|
      record.body = body
      record.title = title
    end
  end

  test "validates moderate: true rejects what the wordlist flags, like moderates mode: :block" do
    record = note(body: OBJECTIONABLE)

    refute_predicate record, :valid?
    assert record.errors.added?(:body, :objectionable_content)
    assert_equal ["Body contains language that isn't allowed"], record.errors.full_messages
  end

  test "clean and blank values pass" do
    assert_predicate note(body: "hello friendly neighbor"), :valid?
    assert_predicate note(body: ""), :valid?
  end

  test "a message: option replaces the default copy" do
    record = note(title: OBJECTIONABLE)

    refute_predicate record, :valid?
    assert_equal ["keep it clean"], record.errors[:title]
  end

  test "it uses the wordlist's configured exclusions" do
    Moderate.configure { |config| config.excluded_words = %w[bitch] }

    assert_predicate note(body: OBJECTIONABLE), :valid?
  end

  test "a :block rejection reads as copy, in English and Spanish" do
    Moderate.configure { |config| config.filter "Comment", :body, with: :wordlist, mode: :block }
    comment = Comment.new(user: User.new(name: "A", email: "a@example.com"), body: OBJECTIONABLE)

    refute_predicate comment, :valid?
    assert_equal ["Body contains language that isn't allowed"], comment.errors.full_messages
    I18n.with_locale(:es) do
      comment.valid?
      assert_equal "contiene lenguaje no permitido", comment.errors[:body].first
    end
  end
end
