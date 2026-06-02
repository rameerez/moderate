# frozen_string_literal: true

require "test_helper"

# Tests for the class-level DSL the engine adds to every ActiveRecord model:
# `has_moderation_capabilities`, `reportable`, and `moderates` (Moderate::Macros, extended onto
# ActiveRecord::Base via `ActiveSupport.on_load(:active_record)`).
#
# Two angles:
#   - the dummy host models (User/Comment) prove the macros wired the concerns,
#     field whitelists, and reportable registry correctly at BOOT;
#   - anonymous AR classes declared INSIDE a test prove `moderates` records a
#     Configuration FilterPolicy — declared after the suite's setup `reset!`, so the
#     assertion sees the policy the macro just created rather than a boot-time one
#     that reset! wiped.
class MacrosTest < ActiveSupport::TestCase
  # --- has_moderation_capabilities (Actor + Reportable) ----------------------

  test "has_moderation_capabilities includes Moderate::Actor (and Reportable, since a user is reportable)" do
    assert User.include?(Moderate::Actor)
    # Actor pulls in Reportable — Apple 1.2 / Play UGC require reporting USERS too.
    assert User.include?(Moderate::Reportable)
  end

  test "has_moderation_capabilities gives an actor the report!/block! surface" do
    actor = create_user
    %i[report! block! unblock! blocks? blocked_by? blocked_with?].each do |method|
      assert_respond_to actor, method, "expected actor to respond to ##{method}"
    end
  end

  test "an actor can report content through report! (the macro-provided helper)" do
    reporter = create_user
    author = create_user
    comment = Comment.create!(user: author, body: "a perfectly fine comment")

    report = reporter.report!(comment, category: :harassment, details: "Won't stop")

    assert_instance_of Moderate::Report, report
    assert_equal reporter, report.reporter
    assert_equal comment, report.reportable
    assert_equal "harassment", report.category
    # `details:` maps onto the Report's `message`.
    assert_equal "Won't stop", report.message
    # community intake by default.
    assert report.community?
  end

  test "an actor can block / unblock / query block edges via the macro surface" do
    a = create_user
    b = create_user

    a.block!(b)
    assert a.blocks?(b)
    assert b.blocked_by?(a)
    # blocked_with? is symmetric — the predicate to check in product code.
    assert a.blocked_with?(b)
    assert b.blocked_with?(a)
    # never "blocked with" yourself.
    refute a.blocked_with?(a)

    a.unblock!(b)
    refute a.blocks?(b)
  end

  # --- reportable -----------------------------------------------------------

  test "reportable narrows the reportable field whitelist" do
    # Comment declared `reportable :body`; only :body is reportable.
    comment = Comment.create!(user: create_user, body: "fine")
    assert comment.reportable_field_allowed?("body")
    refute comment.reportable_field_allowed?("user_id")
  end

  test "bare reportable (no fields) reports the whole record — a blank field is allowed" do
    klass = anonymous_reportable_class
    record = klass.new
    # No declared fields ⇒ the whole record is reportable ⇒ a blank field is allowed,
    # while a named field is not (nothing was whitelisted).
    assert record.reportable_field_allowed?("")
    assert record.reportable_field_allowed?(nil)
    refute record.reportable_field_allowed?("anything")
  end

  test "reportable self-registers the class in Moderate.reportable_classes" do
    assert_includes Moderate.reportable_classes, User
    assert_includes Moderate.reportable_classes, Comment
  end

  test "reportable_fields is a reader and a writer" do
    assert_equal ["body"], Comment.reportable_fields
  end

  # --- moderates ------------------------------------------------------------

  test "moderates includes ContentFilterable and registers the field" do
    assert Comment.include?(Moderate::ContentFilterable)
    assert_includes Comment.moderation_filtered_fields, "body"
  end

  test "moderates records a Configuration FilterPolicy keyed by [class, field]" do
    # Declared AFTER setup's reset!, so config.filters reflects exactly this macro.
    klass = Class.new(ApplicationRecord) do
      self.table_name = "comments"
      def self.name = "MacroFilteredComment"
      moderates :body, with: :wordlist, mode: :block
    end

    policy = Moderate.filter_policy_for(klass, "body")
    assert_equal "MacroFilteredComment", policy.class_name
    assert_equal "body", policy.field
    assert_equal :wordlist, policy.adapter
    assert_equal :block, policy.mode
    assert_predicate policy, :block?
  end

  test "moderates without mode/adapter inherits the config defaults" do
    klass = Class.new(ApplicationRecord) do
      self.table_name = "comments"
      def self.name = "MacroDefaultComment"
      moderates :body
    end

    policy = Moderate.filter_policy_for(klass, "body")
    # default_filter_mode is :block and filter_adapter is :wordlist out of the box.
    assert_equal Moderate.config.default_filter_mode, policy.mode
    assert_equal Moderate.config.filter_adapter, policy.adapter
  end

  test "filter_policy_for falls back to an :off policy for an unmoderated field" do
    policy = Moderate.filter_policy_for(Comment, "definitely_not_moderated")
    assert_predicate policy, :off?
  end

  test "the :block filter macro rejects an objectionable save synchronously" do
    # Re-establish the policy (setup reset it): Comment#body, wordlist, :block.
    Moderate.config.filter "Comment", :body, with: :wordlist, mode: :block

    bad = Comment.new(user: create_user, body: "you stupid bitch")
    refute bad.valid?
    assert bad.errors[:body].any?

    good = Comment.new(user: create_user, body: "a thoroughly polite remark")
    assert_predicate good, :valid?
  end

  test "macros are idempotent — re-including a concern doesn't double-wire" do
    before = Comment.ancestors.count(Moderate::ContentFilterable)
    Comment.moderates :body # re-declare
    after = Comment.ancestors.count(Moderate::ContentFilterable)
    assert_equal before, after
  end

  private

  def anonymous_reportable_class
    Class.new(ApplicationRecord) do
      self.table_name = "comments"
      def self.name = "AnonymousBareReportable"
      reportable # no fields → whole-record reportable
    end
  end

  def create_user(**attributes)
    @user_seq ||= 0
    @user_seq += 1
    User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
  end
end
