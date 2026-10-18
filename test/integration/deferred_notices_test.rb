# frozen_string_literal: true

require "test_helper"

module Moderate
  # A comment a moderator can remove.
  class DeferralComment < ::ApplicationRecord
    self.table_name = "comments"

    belongs_to :user
    has_reportable_content :body

    def reported_owner = user

    def remove_reported_field!(field)
      field.to_s == "body" && update!(body: nil)
    end
  end

  # Notices wait for the OUTERMOST commit (Moderate::DeferredNotices) — a host that
  # decides, reports or blocks inside a transaction of its own and rolls it back tells
  # nobody — on every supported Rails (7.1, 7.2, 8.x alike: record-level after_commit).
  #
  # Not transactional: the test's own wrapping transaction would sit around every
  # "outer" transaction here, and only a real commit proves the timing. Each test
  # commits for real and the teardown deletes what it wrote.
  class DeferredNoticesTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      Moderate.configure do |config|
        config.audit = ->(event) { ModerateTestRecorder.audit(event) }
        config.notify = ->(event) { ModerateTestRecorder.notify(event) }
        config.ban_handler = ModerateTestRecorder.method(:ban_handler)
      end
      ModerateTestRecorder.clear
      tag = SecureRandom.hex(3)
      @moderator = User.create!(name: "Mod #{tag}")
      @author = User.create!(name: "Author #{tag}", email: "author-#{tag}@example.com")
      @reporter = User.create!(name: "Reporter #{tag}", email: "reporter-#{tag}@example.com")
      @comment = DeferralComment.create!(user: @author, body: "slur")
    end

    teardown do
      [Moderate::Appeal, Moderate::Flag, Moderate::Block, Moderate::Report].each(&:delete_all)
      ::Comment.delete_all
      ::User.delete_all
    end

    # --- Decisions --------------------------------------------------------------

    test "a report decision is announced after the outer commit, not before" do
      report = file_report

      ActiveRecord::Base.transaction do
        report.resolve!(by: @moderator, note: "Slur.", remove_content: true, ban_user: true)
        assert_empty sent, "nothing before the commit"
      end

      assert_equal %i[affected_user_decision content_removed report_decision user_banned], sent.sort
    end

    test "a report decision rolled back by the host announces nothing" do
      report = file_report

      ActiveRecord::Base.transaction do
        report.resolve!(by: @moderator, note: "Slur.", remove_content: true, ban_user: true)
        raise ActiveRecord::Rollback
      end

      assert_predicate report.reload, :open?
      assert_empty sent
    end

    test "a flag escalation rolled back by the host announces nothing; committed, it does" do
      flag = file_flag

      ActiveRecord::Base.transaction do
        flag.action!(by: @moderator, note: "Slur.", remove_content: true)
        raise ActiveRecord::Rollback
      end
      assert_predicate flag.reload, :pending?
      assert_empty sent

      ActiveRecord::Base.transaction do
        Moderate::Flag.find(flag.id).action!(by: @moderator, note: "Slur.", remove_content: true)
        assert_empty sent
      end
      assert_equal %i[affected_user_decision content_removed], sent.sort
    end

    test "an appeal decision waits for the commit" do
      report = file_report
      report.dismiss!(by: @moderator, note: "No violation.")
      appeal = Moderate::Appeal.create!(report: report, appellant: @reporter, reason: "Please look again.")
      ModerateTestRecorder.clear

      ActiveRecord::Base.transaction do
        appeal.reject!(by: @moderator, note: "Stands.")
        raise ActiveRecord::Rollback
      end
      assert_empty sent

      appeal.reload.reject!(by: @moderator, note: "Stands.")
      assert_equal %i[appeal_decision], sent
    end

    # --- Intake and blocks -------------------------------------------------------

    test "a report's receipt is never sent for a report the host rolled back" do
      ActiveRecord::Base.transaction do
        file_report
        assert_empty sent
        raise ActiveRecord::Rollback
      end

      assert_equal 0, Moderate::Report.count
      assert_empty sent
    end

    test "a report's receipt goes out after the commit" do
      ActiveRecord::Base.transaction do
        file_report
        assert_empty sent
      end

      assert_equal %i[report_received], sent
    end

    test "a block or an unblock rolled back by the host announces nothing" do
      ActiveRecord::Base.transaction do
        @reporter.block!(@author)
        assert_empty sent
        raise ActiveRecord::Rollback
      end
      assert_empty sent
      assert_not @reporter.blocks?(@author)

      @reporter.block!(@author)
      assert_equal %i[user_blocked], sent

      ActiveRecord::Base.transaction do
        @reporter.unblock!(@author)
        raise ActiveRecord::Rollback
      end
      assert_equal %i[user_blocked], sent
      @reporter.unblock!(@author)
      assert_equal %i[user_blocked user_unblocked], sent
    end

    private

    def sent = ModerateTestRecorder.notifications.map(&:name)

    def file_report
      @reporter.report!(@comment, category: :hate, details: "Slur", field: :body).tap { ModerateTestRecorder.clear }
    end

    def file_flag
      Moderate::Flag.flag!(
        flaggable: @comment, field: "body", owner: @author, source: "text_filter", mode: "flag",
        excerpt: "slur", categories: ["hate"], scores: {}, context: {}
      ).tap { ModerateTestRecorder.clear }
    end
  end
end
