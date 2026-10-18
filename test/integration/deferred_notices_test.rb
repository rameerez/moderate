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

    # --- The queue belongs to the row, not to one Ruby instance --------------------
    #
    # Active Record runs a row's commit callbacks on ONE instance saved in the
    # transaction: the first saved (`run_commit_callbacks_on_first_saved_instances_in_transaction`
    # true, the Rails default) or the freshest (false). Host code may save another
    # instance of the same row before or after ours. Either way the notice goes once.

    [true, false].each do |first_saved|
      %i[before after].each do |when_other|
        test "a notice survives another instance saved #{when_other} it (first_saved=#{first_saved})" do
          with_first_saved_instances(first_saved) do
            flag = file_flag
            calls = []

            ActiveRecord::Base.transaction do
              touch_other_instance(flag) if when_other == :before
              flag.update!(excerpt: "ours")
              flag.after_commit_notice { calls << :sent }
              touch_other_instance(flag) if when_other == :after
              assert_empty calls
            end

            assert_equal [:sent], calls
          end
        end

        test "a notice is dropped on rollback, another instance saved #{when_other} (first_saved=#{first_saved})" do
          with_first_saved_instances(first_saved) do
            flag = file_flag
            calls = []

            ActiveRecord::Base.transaction do
              touch_other_instance(flag) if when_other == :before
              flag.update!(excerpt: "ours")
              flag.after_commit_notice { calls << :sent }
              touch_other_instance(flag) if when_other == :after
              raise ActiveRecord::Rollback
            end

            assert_empty calls
            assert_nothing_left_queued(flag)
          end
        end
      end
    end

    test "a decision's notices survive the host saving another instance of the report afterwards" do
      with_first_saved_instances(false) do
        report = file_report

        ActiveRecord::Base.transaction do
          report.resolve!(by: @moderator, note: "Slur.", remove_content: true)
          Moderate::Report.find(report.id).update!(resolution_note: "Slur, confirmed.")
        end

        assert_equal %i[affected_user_decision content_removed report_decision], sent.sort
      end
    end

    test "two rows queued in one transaction each send" do
      first = file_flag
      second = Moderate::Flag.flag!(
        flaggable: @comment, field: "image", owner: @author, source: "manual", mode: "flag",
        excerpt: "x", categories: [], scores: {}, context: {}
      )
      assert_not_equal first, second
      calls = []

      ActiveRecord::Base.transaction do
        [first, second].each do |flag|
          flag.update!(excerpt: "queued")
          flag.after_commit_notice { calls << flag.id }
        end
      end

      assert_equal [first.id, second.id].sort, calls.sort
    end

    test "nested transactions send once, at the outermost commit" do
      flag = file_flag
      calls = []

      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction do # joins the outer one
          flag.update!(excerpt: "inner")
          flag.after_commit_notice { calls << :joined }
        end
        ActiveRecord::Base.transaction(requires_new: true) do # a savepoint, released
          flag.update!(excerpt: "savepoint")
          flag.after_commit_notice { calls << :savepoint }
        end
        assert_empty calls, "not at the inner ends"
      end

      assert_equal %i[joined savepoint], calls
    end

    test "a rolled-back savepoint drops only its own notices" do
      flag = file_flag
      calls = []

      ActiveRecord::Base.transaction do
        flag.update!(excerpt: "outer")
        flag.after_commit_notice { calls << :outer }
        ActiveRecord::Base.transaction(requires_new: true) do
          flag.update!(excerpt: "savepoint")
          flag.after_commit_notice { calls << :savepoint }
          raise ActiveRecord::Rollback
        end
      end

      assert_equal [:outer], calls
    end

    # --- The transaction owns the notice -------------------------------------------

    test "a notice queued without saving its row is sent once at commit" do
      flag = file_flag
      calls = []

      ActiveRecord::Base.transaction do
        flag.after_commit_notice { calls << :sent } # the flag row is never saved here
        assert_empty calls
      end

      assert_equal [:sent], calls
      assert_nothing_left_queued(flag)
      assert_equal [:sent], calls, "and not again later"
    end

    test "a notice queued without saving its row is dropped on rollback" do
      flag = file_flag
      calls = []

      ActiveRecord::Base.transaction do
        flag.after_commit_notice { calls << :sent }
        raise ActiveRecord::Rollback
      end

      assert_empty calls
      assert_nothing_left_queued(flag)
      assert_empty calls
    end

    test "an exception ending the transaction drops the notice and leaves nothing behind" do
      flag = file_flag
      calls = []

      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          flag.update!(excerpt: "doomed")
          flag.after_commit_notice { calls << :sent }
          raise "boom"
        end
      end

      assert_empty calls
      assert_nothing_left_queued(flag)
      assert_empty calls
    end

    test "under a parent that isn't joinable, a notice is sent when its savepoint is released, like after_commit" do
      calls = []
      flag = file_flag

      ActiveRecord::Base.transaction(joinable: false) do
        ActiveRecord::Base.transaction do
          flag.after_commit_notice { calls << :sent }
        end
        assert_equal [:sent], calls, "Active Record's after_commit runs here too"
      end
    end

    test "with no transaction open, a notice is sent at once" do
      calls = []
      file_flag.after_commit_notice { calls << :now }

      assert_equal [:now], calls
    end

    private

    def sent = ModerateTestRecorder.notifications.map(&:name)

    # Nothing from an earlier transaction may surface later: saving the same row
    # again in a fresh transaction that commits sends only that transaction's notice.
    def assert_nothing_left_queued(row)
      own = []
      ActiveRecord::Base.transaction do
        Moderate::Flag.find(row.id).update!(excerpt: "later #{SecureRandom.hex(2)}")
        row.after_commit_notice { own << :own }
      end
      assert_equal [:own], own
    end

    def touch_other_instance(flag)
      Moderate::Flag.find(flag.id).update!(excerpt: "theirs #{SecureRandom.hex(2)}")
    end

    def with_first_saved_instances(value)
      previous = ActiveRecord::Base.run_commit_callbacks_on_first_saved_instances_in_transaction
      ActiveRecord::Base.run_commit_callbacks_on_first_saved_instances_in_transaction = value
      yield
    ensure
      ActiveRecord::Base.run_commit_callbacks_on_first_saved_instances_in_transaction = previous
    end

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

  # The same rules under Rails' transactional tests, where every test runs inside a
  # wrapper transaction that is not joinable: a notice is sent when the gem's (or the
  # host's) own transaction is released, exactly when a record's after_commit runs.
  # This is what hosts' own transactional tests see.
  class DeferredNoticesUnderTestWrapperTest < ActiveSupport::TestCase
    setup do
      Moderate.configure { |config| config.notify = ->(event) { ModerateTestRecorder.notify(event) } }
      ModerateTestRecorder.clear
      @author = User.create!(name: "Wrapped")
    end

    test "a notice is sent when its transaction is released inside the test wrapper, with after_commit" do
      calls = []

      ActiveRecord::Base.transaction do
        flag = Moderate::Flag.flag!(
          flaggable: @author, field: "name", owner: @author, source: "manual", mode: "flag",
          excerpt: nil, categories: [], scores: {}, context: {}
        )
        flag.after_commit_notice { calls << :notice }
        assert_empty calls
        assert_empty ModerateTestRecorder.notifications_named(:content_flagged), "nor the flag's after_commit"
      end

      assert_equal [:notice], calls
      assert_equal 1, ModerateTestRecorder.notifications_named(:content_flagged).size, "both at the same release"
    end

    test "inside the wrapper, a rolled-back transaction drops its notice" do
      calls = []

      ActiveRecord::Base.transaction do
        @author.update!(name: "Wrapped, edited")
        Moderate::DeferredNotices.defer(ActiveRecord::Base.connection) { calls << :notice }
        raise ActiveRecord::Rollback
      end

      assert_empty calls
    end
  end
end
