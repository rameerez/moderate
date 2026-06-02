# frozen_string_literal: true

require "test_helper"

module Moderate
  module Services
    # Tests for Moderate::Services::ResolveFlag — the decision on an auto-filter Flag.
    #
    # A Flag is the lightweight triage record :flag-mode filtering leaves behind. Resolving
    # it is the simplest resolver, but follows the same discipline:
    #   - atomic transition under a row lock;
    #   - a NOTE IS MANDATORY (the moderator's rationale is the audit trail);
    #   - the review is audited via Moderate.audit (the `flag_decision` event);
    #   - the DOUBLE-REVIEW case is BENIGN: re-reviewing an already-closed flag returns
    #     it as-is (not an error), because double-reviewing a flag is harmless and a
    #     friendly "already done" suits a fast triage queue (this differs from ResolveReport,
    #     where a re-decide is a hard error to prevent a double-ban — see that test).
    #   - resolving a flag does NOT itself run removal/bans (those are a report concern).
    class ResolveFlagTest < ActiveSupport::TestCase
      setup do
        Moderate.configure do |config|
          config.audit = ->(event) { ModerateTestRecorder.audit(event) }
          config.notify = ->(event) { ModerateTestRecorder.notify(event) }
        end
        ModerateTestRecorder.clear
      end

      test "actioning a flag closes it, stamps the reviewer, and audits the review" do
        moderator = User.create!(name: "Mod")
        flag = create_flag

        Moderate::Services::ResolveFlag.new(flag, by: moderator).action!(note: "Image removed manually.")

        flag.reload
        assert_equal "actioned", flag.status
        assert_equal moderator, flag.reviewed_by
        assert_predicate flag.reviewed_at, :present?
        assert_equal "Image removed manually.", flag.resolution_note

        audits = ModerateTestRecorder.audits_named(:flag_decision)
        assert_equal 1, audits.size
        assert_equal flag, audits.first.subject
        assert_equal moderator, audits.first.actor
        assert_equal flag.field, audits.first.payload[:field]
      end

      test "dismissing a flag closes it as a false positive and audits" do
        moderator = User.create!(name: "Mod")
        flag = create_flag

        Moderate::Services::ResolveFlag.new(flag, by: moderator).dismiss!(note: "Acceptable, false positive.")

        assert_equal "dismissed", flag.reload.status
        assert_equal 1, ModerateTestRecorder.audits_named(:flag_decision).size
      end

      test "a flag cannot be closed without a note" do
        moderator = User.create!(name: "Mod")
        flag = create_flag

        error = assert_raises(ActiveRecord::RecordInvalid) do
          Moderate::Services::ResolveFlag.new(flag, by: moderator).dismiss!(note: "")
        end
        assert_predicate error.record.errors[:resolution_note], :present?

        # Still pending, no audit written.
        assert_equal "pending", flag.reload.status
        assert_empty ModerateTestRecorder.audits_named(:flag_decision)
      end

      test "re-reviewing an already-closed flag is a benign no-op returning the flag (not an error)" do
        moderator = User.create!(name: "Mod")
        flag = create_flag

        Moderate::Services::ResolveFlag.new(flag, by: moderator).action!(note: "First review.")
        ModerateTestRecorder.clear

        # Unlike a report, double-reviewing a flag is harmless: the in-lock `pending?`
        # re-check returns the flag as-is rather than raising.
        result = Moderate::Services::ResolveFlag.new(flag, by: moderator).dismiss!(note: "Second review.")
        assert_equal flag, result

        flag.reload
        # The first review stands; the second neither overwrote it nor re-audited.
        assert_equal "actioned", flag.status
        assert_equal "First review.", flag.resolution_note
        assert_empty ModerateTestRecorder.audits_named(:flag_decision)
      end

      private

      # A pending Flag straight from the model's `flag!` entry point — the same shape the
      # Filterable concern files. Host-agnostic: the flaggable is a dummy Comment, the
      # source is a generic text_filter, no host vocabulary anywhere.
      def create_flag
        author = User.create!(name: "Author")
        comment = Comment.create!(user: author, body: "ok body")
        Moderate::Flag.flag!(
          flaggable: comment,
          field: "body",
          owner: author,
          source: "text_filter",
          mode: "flag",
          excerpt: "ok body",
          categories: ["hate"],
          scores: { "hate" => 0.97 },
          context: { "human_review_required" => true }
        )
      end
    end
  end
end
