# frozen_string_literal: true

require "test_helper"

module Moderate
  # A comment whose body a moderator can remove (Comment itself removes nothing). Its
  # own base class, not a Comment subclass, so the polymorphic flaggable_type names
  # it and the flag loads it back as itself.
  class EscalationComment < ::ApplicationRecord
    self.table_name = "comments"

    belongs_to :user
    has_reportable_content :body

    # Every field a moderator removed, across instances, for "removed once" assertions.
    cattr_accessor :removed_fields, default: []

    def reported_owner = user
    def moderation_snapshot(field) = (body if field.to_s == "body")

    def remove_reported_field!(field)
      return false unless %w[body image].include?(field.to_s)

      update!(body: nil) if field.to_s == "body"
      removed_fields << field.to_s
      true
    end
  end

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
        EscalationComment.removed_fields = []
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

      # --- Enforcement escalates to a report ---------------------------------

      test "remove_content opens a system report, resolves it, and removes the content" do
        moderator = User.create!(name: "Mod")
        flag = create_flag(comment_class: EscalationComment)
        comment = flag.flaggable

        decision = Moderate::Services::ResolveFlag.new(flag, by: moderator)
        decision.action!(note: "Slur in a DM.", remove_content: true)

        report = flag.reload.report
        assert_equal "actioned", flag.status
        assert_equal report.id, flag.context["report_id"]
        assert_equal "actioned", report.status
        assert_nil report.reporter, "a system report has no reporter"
        assert_equal "body", report.reported_field
        assert_equal comment.user, report.reported_user
        assert_equal "hate", report.category, "the flag's category, when the community list has it"
        assert_equal true, report.resolution_actions["remove_content"]
        assert_predicate report.appeal_deadline_at, :present?, "a restriction opens the appeal window"
        assert_nil comment.reload.body, "removed through the reportable's remove_reported_field!"

        assert_empty ModerateTestRecorder.notifications_named(:report_received), "no receipt: nobody filed it"
        assert_empty ModerateTestRecorder.notifications_named(:report_decision), "no reporter to tell"
        decision = ModerateTestRecorder.notifications_named(:affected_user_decision).sole
        assert_equal [comment.user], decision.recipients
        assert_equal report.id, ModerateTestRecorder.audits_named(:flag_decision).sole.payload[:report_id]
      end

      test "enforcement reuses the open report a person already filed on the same content" do
        moderator = User.create!(name: "Mod")
        reporter = User.create!(name: "Reporter", email: "reporter@example.com")
        flag = create_flag(comment_class: EscalationComment)
        filed = reporter.report!(flag.flaggable, category: :harassment, details: "Saw this", field: :body)
        ModerateTestRecorder.clear

        assert_no_difference -> { Moderate::Report.count } do
          flag.action!(by: moderator, note: "Confirmed.", remove_content: true)
        end

        assert_equal filed, flag.reload.report
        assert_equal "actioned", filed.reload.status
        decision = ModerateTestRecorder.notifications_named(:report_decision).sole
        assert_equal [reporter], decision.recipients, "the person who reported it hears the outcome"
      end

      test "ban_user bans the flag's owner through the ban_handler, with a statement of reasons" do
        Moderate.configure do |config|
          config.ban_handler = ModerateTestRecorder.method(:ban_handler)
        end
        moderator = User.create!(name: "Mod")
        flag = create_flag

        flag.action!(by: moderator, note: "Repeat offender.", ban_user: true)

        assert_equal [{ user: flag.owner, by: moderator, reason: "Repeat offender." }], ModerateTestRecorder.bans
        assert_equal "account_suspended", flag.reload.report.decision_visibility
        assert_equal 1, ModerateTestRecorder.notifications_named(:affected_user_decision).size
      end

      test "decision notices go out after the flag is closed" do
        statuses = []
        Moderate.configure do |config|
          config.notify = lambda do |event|
            statuses << Moderate::Flag.find(@flag_id).status if event.name == :affected_user_decision
            true
          end
        end
        flag = create_flag(comment_class: EscalationComment)
        @flag_id = flag.id

        flag.action!(by: User.create!(name: "Mod"), note: "Removed.", remove_content: true)

        assert_equal ["actioned"], statuses
      end

      test "a flag already decided enforces nothing a second time" do
        Moderate.configure do |config|
          config.ban_handler = ModerateTestRecorder.method(:ban_handler)
        end
        moderator = User.create!(name: "Mod")
        flag = create_flag

        flag.action!(by: moderator, note: "First.", ban_user: true)
        assert_no_difference -> { Moderate::Report.count } do
          Moderate::Flag.find(flag.id).action!(by: moderator, note: "Second.", ban_user: true)
        end

        assert_equal 1, ModerateTestRecorder.bans.size
      end

      test "a triage close opens no report" do
        flag = create_flag

        assert_no_difference -> { Moderate::Report.count } do
          flag.action!(by: User.create!(name: "Mod"), note: "Looked at it.")
        end
        assert_nil flag.reload.report
      end

      test "a failed enforcement leaves the flag pending" do
        flag = create_flag(field: "image")

        assert_raises(ActiveRecord::RecordInvalid) do
          flag.action!(by: User.create!(name: "Mod"), note: "Remove it.", remove_content: true)
        end

        assert_predicate flag.reload, :pending?, "Comment removes nothing, so the decision is refused"
        assert_equal 0, Moderate::Report.count, "and the system report rolled back with it"
      end

      test "a flag on a field people can't report still enforces through a system report" do
        flag = create_flag(comment_class: EscalationComment, field: "image")

        flag.action!(by: User.create!(name: "Mod"), note: "Explicit photo.", remove_content: true)

        report = flag.reload.report
        assert_equal "image", report.reported_field
        assert_equal "actioned", report.status
        assert_equal ["image"], EscalationComment.removed_fields
      end

      test "a second flag on the same content closes against the decision already taken, enforcing nothing again" do
        moderator = User.create!(name: "Mod")
        first = create_flag(comment_class: EscalationComment)
        second = Moderate::Flag.flag!(
          flaggable: first.flaggable, field: "body", owner: first.owner, source: "manual", mode: "flag",
          excerpt: "ok body", categories: [], scores: {}, context: {}
        )

        first.action!(by: moderator, note: "Removed.", remove_content: true)
        assert_no_difference -> { Moderate::Report.count } do
          second.action!(by: moderator, note: "Same thing.", remove_content: true)
        end

        assert_equal first.reload.report, second.reload.report
        assert_equal "actioned", second.status
        assert_equal ["body"], EscalationComment.removed_fields, "removed once"
        assert_equal 1, ModerateTestRecorder.notifications_named(:affected_user_decision).size
      end

      test "a new kind of enforcement on the same content is a new decision" do
        Moderate.configure { |config| config.ban_handler = ModerateTestRecorder.method(:ban_handler) }
        moderator = User.create!(name: "Mod")
        first = create_flag(comment_class: EscalationComment)
        second = Moderate::Flag.flag!(
          flaggable: first.flaggable, field: "body", owner: first.owner, source: "manual", mode: "flag",
          excerpt: "ok body", categories: [], scores: {}, context: {}
        )

        first.action!(by: moderator, note: "Removed.", remove_content: true)
        second.action!(by: moderator, note: "And banned.", ban_user: true)

        assert_not_equal first.reload.report, second.reload.report
        assert_equal 1, ModerateTestRecorder.bans.size
      end

      # --- Automated-means disclosure on escalation ----------------------------

      test "enforcing a classifier's flag through a person's earlier report discloses the automation" do
        author = User.create!(name: "Author", email: "a-early@example.com")
        comment = EscalationComment.create!(user: author, body: "slur")
        reporter = User.create!(name: "Reporter", email: "early@example.com")
        report = reporter.report!(comment, category: :hate, details: "Slur", field: :body)
        assert_not_predicate report, :automated_processing_used?, "no classifier had looked yet"
        flag = Moderate::Flag.flag!(
          flaggable: comment, field: "body", owner: author, source: "text_filter", mode: "flag",
          excerpt: "slur", categories: ["hate"], scores: {}, context: {}
        )
        ModerateTestRecorder.clear

        flag.action!(by: User.create!(name: "Mod"), note: "Slur.", remove_content: true)

        assert_equal report, flag.reload.report
        assert_predicate report.reload, :automated_processing_used?
        assert_includes report.automated_processing["flag_ids"], flag.id
        assert_equal true, ModerateTestRecorder.notifications_named(:affected_user_decision).sole.payload[:automated]
      end

      test "a manual flag is not automated means" do
        comment = EscalationComment.create!(user: User.create!(name: "Author", email: "a-manual@example.com"), body: "rude")
        flag = Moderate::Flag.flag_for_review!(comment, field: :body, by: User.create!(name: "Admin"))

        flag.action!(by: User.create!(name: "Mod"), note: "Rude.", remove_content: true)

        assert_not_predicate flag.reload.report, :automated_processing_used?
        assert_equal false, ModerateTestRecorder.notifications_named(:affected_user_decision).sole.payload[:automated]
      end

      test "a ban with no ban_handler is refused and the flag stays pending" do
        Moderate.config.ban_handler = nil
        flag = create_flag

        assert_raises(Moderate::ConfigurationError) do
          flag.action!(by: User.create!(name: "Mod"), note: "Ban.", ban_user: true)
        end

        assert_predicate flag.reload, :pending?
        assert_equal 0, Moderate::Report.count, "the system report rolled back with it"
      end

      test "a classifier subcategory maps onto the community category, else other" do
        assert_equal "hate", escalation_category_for(["hate/threatening"])
        assert_equal "other", escalation_category_for(["violence/graphic"])
        Moderate.config.report_categories = %w[spam abuse]
        assert_equal "spam", escalation_category_for(["violence"]), "a list without other falls back to its first entry"
      end

      private

      def escalation_category_for(categories)
        flag = Moderate::Flag.new(categories: categories)
        Moderate::Services::ResolveFlag.new(flag, by: nil).send(:escalation_category)
      end

      # A pending Flag straight from the model's `flag!` entry point — the same shape the
      # Filterable concern files. Host-agnostic: the flaggable is a dummy Comment, the
      # source is a generic text_filter, no host vocabulary anywhere.
      def create_flag(comment_class: Comment, field: "body")
        author = User.create!(name: "Author", email: "author#{User.count}@example.com")
        comment = comment_class.create!(user: author, body: "ok body")
        Moderate::Flag.flag!(
          flaggable: comment,
          field: field,
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
