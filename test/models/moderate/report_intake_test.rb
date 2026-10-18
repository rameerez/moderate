# frozen_string_literal: true

require "test_helper"

module Moderate
  # Content only the people in a conversation may report — chats' rule
  # (Chats::Message#report_visible_to?: a participant, never the author).
  class ConversationLine < ::ApplicationRecord
    self.table_name = "comments"

    belongs_to :user
    has_reportable_content :body

    cattr_accessor :participant_ids, default: []

    def reported_owner = user
    def moderation_snapshot(field) = (body if field.to_s == "body")
    def moderation_content_type = "message"

    def report_visible_to?(viewer, **)
      viewer.present? && viewer.id != user_id && participant_ids.include?(viewer.id)
    end
  end

  # A host whose own word for its content isn't one of the gem's buckets.
  class RideNote < ::ApplicationRecord
    self.table_name = "comments"

    belongs_to :user
    has_reportable_content :body

    def reported_owner = user
    def moderation_content_type(field) = (field.to_s == "body" ? "ride" : nil)
  end

  # Intake rules the in-app report path enforces: who may report what, "report and
  # block", and the content type a report is filed under.
  class ReportIntakeTest < ActiveSupport::TestCase
    setup do
      Moderate.configure do |config|
        config.audit = ->(event) { ModerateTestRecorder.audit(event) }
        config.notify = ->(event) { ModerateTestRecorder.notify(event) }
        config.on_block = ModerateTestRecorder.method(:on_block)
      end
      ModerateTestRecorder.clear
      @author = create_user
      @participant = create_user
      @outsider = create_user
      ConversationLine.participant_ids = [@author.id, @participant.id]
      @line = ConversationLine.create!(user: @author, body: "see you on the ladder")
    end

    # --- Who may report ---------------------------------------------------------

    test "a participant may report a line" do
      report = @participant.report!(@line, category: :harassment, details: "Rude", field: :body)

      assert_predicate report, :persisted?
    end

    test "someone the content isn't visible to is refused, whatever target they hold" do
      error = assert_raises(ActiveRecord::RecordInvalid) do
        @outsider.report!(@line, category: :harassment, details: "Rude", field: :body)
      end

      assert_includes error.record.errors[:reportable], "isn't something you can report"
      assert_equal 0, Moderate::Report.count
    end

    test "reporting yourself still explains itself as a self-report" do
      error = assert_raises(ActiveRecord::RecordInvalid) { @author.report!(@author, category: :spam, details: "me") }

      assert_predicate error.record.errors[:reported_user], :any?
      assert_empty error.record.errors[:reportable]
    end

    test "a DSA notice and a system report are not visibility-checked" do
      notice = Moderate::Report.create!(
        reportable: @line, intake_kind: "dsa", category: "illegal_content", legal_reason: "violence",
        legal_country_code: "ES", content_type: "message", notifier_name: "N", notifier_email: "n@example.com",
        message: "Threat", good_faith_confirmed: true
      )
      system = Moderate::Report.create!(
        reportable: @line, category: "other", message: "From a flag", good_faith_confirmed: true
      )

      assert_predicate notice, :persisted?
      assert_predicate system, :persisted?
    end

    # --- Optional details -------------------------------------------------------

    test "an in-app report's details are optional: the category's label stands in" do
      report = @participant.report!(@line, category: :harassment, field: :body)

      assert_equal "Harassment", report.message
      I18n.with_locale(:es) do
        assert_equal "Odio", @participant.report!(@line, category: :hate, field: :body, details: " ").message
      end
    end

    test "a DSA notice still needs its own explanation" do
      notice = Moderate::Report.new(
        reportable: @line, intake_kind: "dsa", category: "illegal_content", legal_reason: "violence",
        legal_country_code: "ES", content_type: "message", notifier_name: "N", notifier_email: "n@example.com",
        good_faith_confirmed: true
      )

      assert_not notice.valid?
      assert_predicate notice.errors[:message], :present?
    end

    # --- Report and block -------------------------------------------------------

    test "block: true blocks the person responsible once the report is filed" do
      report = @participant.report!(@line, category: :harassment, details: "Rude", field: :body, block: true)

      assert_predicate report, :persisted?
      assert @participant.blocks?(@author)
      assert_equal 1, ModerateTestRecorder.notifications_named(:user_blocked).size
    end

    test "without block: nothing is blocked" do
      @participant.report!(@line, category: :harassment, details: "Rude", field: :body)

      assert_not @participant.blocks?(@author)
    end

    test "block: true on content with no person behind it files the report and blocks nobody" do
      line = ConversationLine.create!(user: @author, body: "Automated notice")
      line.define_singleton_method(:reported_owner) { nil }

      report = @participant.report!(line, category: :spam, details: "Bot", field: :body, block: true)

      assert_nil report.reported_user
      assert_equal 0, Moderate::Block.count
    end

    test "report and block is one act: a block that fails files no report and sends no receipt" do
      Moderate.configure { |config| config.on_block = ->(**) { raise "teardown failed" } }

      assert_raises(RuntimeError) do
        @participant.report!(@line, category: :harassment, details: "Rude", field: :body, block: true)
      end

      assert_equal 0, Moderate::Report.count
      assert_equal 0, Moderate::Block.count
      assert_empty ModerateTestRecorder.notifications_named(:report_received)
    end

    test "a refused report blocks nobody" do
      assert_raises(ActiveRecord::RecordInvalid) do
        @outsider.report!(@line, category: :harassment, details: "Rude", field: :body, block: true)
      end

      assert_equal 0, Moderate::Block.count
    end

    # --- Content type -----------------------------------------------------------

    test "the content type comes from the reportable" do
      report = @participant.report!(@line, category: :harassment, details: "Rude", field: :body)

      assert_equal "message", report.content_type
      assert_equal "message", report.snapshot["content_type"], "and is frozen into the evidence"
    end

    test "a person is a user profile" do
      assert_equal "user_profile", @participant.report!(@author, category: :impersonation, details: "Fake").content_type
    end

    test "a host's own word files as other, never failing the intake" do
      note = RideNote.create!(user: @author, body: "pick-up at 9")

      assert_equal "other", @participant.report!(note, category: :spam, details: "Ad", field: :body).content_type
    end

    test "content without a type stays untyped, and an explicit type is kept" do
      comment = Comment.create!(user: @author, body: "hello")

      assert_nil @participant.report!(comment, category: :spam, details: "x", field: :body).content_type
      typed = @outsider.report!(comment, category: :spam, details: "y", field: :body, content_type: "listing")
      assert_equal "listing", typed.content_type
    end

    # --- The signed target ------------------------------------------------------

    test "to_moderation_sgid never expires and resolves back to the record" do
      token = @line.to_moderation_sgid

      assert_equal token, @line.to_moderation_sgid, "the same token on every call"
      assert_equal @line, Moderate::Report.locate_signed_reportable(token)
      travel 2.years do
        assert_equal @line, Moderate::Report.locate_signed_reportable(token)
      end
    end

    private

    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end
  end
end
