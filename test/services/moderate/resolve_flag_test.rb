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

      test "a flag closes against a decision taken on its content while it waited, enforcing nothing again" do
        moderator = User.create!(name: "Mod")
        flag = create_flag(comment_class: EscalationComment)
        reporter = User.create!(name: "Reporter", email: "r-cover@example.com")
        # A person's report on the same content and field, decided directly while the flag waited.
        decided = reporter.report!(flag.flaggable, category: :hate, details: "Slur", field: :body)
        decided.resolve!(by: moderator, note: "Removed.", remove_content: true)
        ModerateTestRecorder.clear

        assert_no_difference -> { Moderate::Report.count } do
          flag.action!(by: moderator, note: "Same thing.", remove_content: true)
        end

        assert_equal decided, flag.reload.report
        assert_equal "actioned", flag.status
        assert_equal ["body"], EscalationComment.removed_fields, "removed once"
        assert_empty ModerateTestRecorder.notifications_named(:affected_user_decision), "no second statement"
      end

      test "while a flag waits on a field, another flag on that field joins it" do
        first = create_flag(comment_class: EscalationComment)

        second = Moderate::Flag.flag!(
          flaggable: first.flaggable, field: "body", owner: first.owner, source: "manual", mode: "flag",
          excerpt: "again", categories: [], scores: {}, context: {}
        )

        assert_equal first, second
        assert_not_predicate second, :previously_new_record?
        assert_equal 1, Moderate::Flag.pending.where(flaggable: first.flaggable, field: "body").count
      end

      test "the escalation exception isn't a host-assignable attribute" do
        flag = create_flag(field: "image")

        assert_raises(ActiveModel::UnknownAttributeError) do
          Moderate::Report.new(reportable: flag.flaggable, reported_field: "image", escalated_from_flag: flag)
        end
        assert_not Moderate::Report.new.respond_to?(:escalated_from_flag=), "private: only ResolveFlag sets it"
      end

      test "even set, the exception holds only for a system report on the flag's own content and field" do
        flag = create_flag(field: "image")
        other = Comment.create!(user: flag.owner, body: "elsewhere")
        reporter = User.create!(name: "Reporter", email: "r-exc@example.com")
        base = { reported_field: "image", category: "other", message: "x", good_faith_confirmed: true }
        dsa = { intake_kind: "dsa", legal_reason: "violence", legal_country_code: "ES", content_type: "other",
                notifier_name: "N", notifier_email: "n@example.com" }

        refused = {
          "other content" => Moderate::Report.new(reportable: other, **base),
          "a person's report" => Moderate::Report.new(reportable: flag.flaggable, reporter: reporter, **base),
          "a DSA notice" => Moderate::Report.new(reportable: flag.flaggable, **base, **dsa)
        }
        refused.each do |what, report|
          report.send(:escalated_from_flag=, flag)
          assert_not report.valid?, what
          assert_predicate report.errors[:reported_field], :any?, what
        end

        system = Moderate::Report.new(reportable: flag.flaggable, **base)
        system.send(:escalated_from_flag=, flag)
        assert_predicate system, :valid?
      end

      # --- Legacy decisions and bans per person ---------------------------------

      test "an older decision that says removed but left the content up doesn't cover a new removal" do
        moderator = User.create!(name: "Mod")
        flag = create_flag(comment_class: EscalationComment)
        legacy = Moderate::Report.create!(
          reportable: flag.flaggable, reported_field: "body", category: "hate", message: "legacy",
          good_faith_confirmed: true
        )
        legacy.update_columns(status: "actioned", resolution_note: "old", resolved_at: Time.current,
                              resolution_actions: { "remove_content" => true }, decision_visibility: "content_removed")
        assert_equal "ok body", flag.flaggable.reload.body, "the legacy shape: recorded a removal, removed nothing"

        flag.action!(by: moderator, note: "Remove it for real.", remove_content: true)

        assert_not_equal legacy, flag.reload.report
        assert_equal ["body"], EscalationComment.removed_fields
        assert_nil flag.flaggable.reload.body
      end

      test "two flags on different fields of one record ban the person once" do
        Moderate.configure { |config| config.ban_handler = ModerateTestRecorder.method(:ban_handler) }
        moderator = User.create!(name: "Mod")
        body_flag = create_flag(comment_class: EscalationComment)
        image_flag = Moderate::Flag.flag!(
          flaggable: body_flag.flaggable, field: "image", owner: body_flag.owner, source: "manual", mode: "flag",
          excerpt: nil, categories: [], scores: {}, context: {}
        )

        body_flag.action!(by: moderator, note: "Slur.", ban_user: true)
        image_flag.action!(by: moderator, note: "And the photo.", ban_user: true)

        assert_equal 1, ModerateTestRecorder.bans.size
        second = image_flag.reload.report
        assert_equal body_flag.reload.report.id, second.resolution_actions["ban_already_applied_by"]
        assert_equal "account_suspended", second.decision_visibility, "true: the account is suspended"
        assert_equal 1, ModerateTestRecorder.notifications_named(:user_banned).size
      end

      test "a second decision on the same person, about other content, doesn't ban again" do
        Moderate.configure { |config| config.ban_handler = ModerateTestRecorder.method(:ban_handler) }
        moderator = User.create!(name: "Mod")
        first = create_flag
        other = Comment.create!(user: first.owner, body: "more abuse")
        second = Moderate::Flag.flag!(
          flaggable: other, field: "body", owner: first.owner, source: "text_filter", mode: "flag",
          excerpt: "more abuse", categories: ["harassment"], scores: {}, context: {}
        )

        first.action!(by: moderator, note: "Abuse.", ban_user: true)
        second.action!(by: moderator, note: "Abuse again.", ban_user: true)

        assert_equal 1, ModerateTestRecorder.bans.size
        assert_equal first.reload.report.id, second.reload.report.resolution_actions["ban_already_applied_by"]
      end

      test "a ban before this conduct was raised doesn't stand in for a new one" do
        Moderate.configure { |config| config.ban_handler = ModerateTestRecorder.method(:ban_handler) }
        moderator = User.create!(name: "Mod")
        earlier = create_flag
        earlier.action!(by: moderator, note: "First episode.", ban_user: true)
        travel 1.day
        later = Moderate::Flag.flag!(
          flaggable: Comment.create!(user: earlier.owner, body: "back at it"), field: "body", owner: earlier.owner,
          source: "text_filter", mode: "flag", excerpt: "x", categories: [], scores: {}, context: {}
        )

        later.action!(by: moderator, note: "Second episode.", ban_user: true)

        assert_equal 2, ModerateTestRecorder.bans.size, "the person may have been unbanned in between"
      end

      test "a new kind of enforcement on the same content is a new decision" do
        Moderate.configure { |config| config.ban_handler = ModerateTestRecorder.method(:ban_handler) }
        moderator = User.create!(name: "Mod")
        first = create_flag(comment_class: EscalationComment)
        first.action!(by: moderator, note: "Removed.", remove_content: true)
        second = Moderate::Flag.flag!( # filed once the first is decided: its field is free again
          flaggable: first.flaggable, field: "body", owner: first.owner, source: "manual", mode: "flag",
          excerpt: "ok body", categories: [], scores: {}, context: {}
        )
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
        author = User.create!(name: "Author", email: "a-manual@example.com")
        comment = EscalationComment.create!(user: author, body: "rude")
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
