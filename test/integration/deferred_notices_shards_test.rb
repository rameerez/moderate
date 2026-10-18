# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Moderate
  # Two databases for one model, as shards (`connects_to shards:`), each its own SQLite
  # file, so this runs the same under the SQLite and the PostgreSQL suites.
  SHARD_DIR = Dir.mktmpdir("moderate-shards")

  class ShardRecord < ::ActiveRecord::Base
    self.abstract_class = true

    connects_to shards: {
      a: { writing: { adapter: "sqlite3", database: File.join(SHARD_DIR, "a.sqlite3") } },
      b: { writing: { adapter: "sqlite3", database: File.join(SHARD_DIR, "b.sqlite3") } }
    }
  end

  class ShardNote < ShardRecord
    self.table_name = "moderate_shard_notes"
    include Moderate::DeferredNotices
  end

  # A notice joins the transaction of the connection it is queued ON
  # (Moderate::DeferredNotices, `after_commit_notice(on:)`): queued for a change saved
  # on shard A, on A's connection, it is sent when A commits and dropped when A rolls
  # back — even from inside a `connected_to` block on shard B, and even when B has a
  # transaction of its own. Nothing is enrolled on B.
  class DeferredNoticesShardsTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      %i[a b].each do |shard|
        on(shard) { ShardRecord.connection.create_table(:moderate_shard_notes, force: true) { |t| t.string :body } }
      end
      @calls = []
    end

    teardown do
      %i[a b].each do |shard|
        on(shard) { ShardRecord.connection.drop_table(:moderate_shard_notes, if_exists: true) }
      end
    end

    test "queued from B on A's connection: sent when A commits, not when B does" do
      on(:a) do
        ShardRecord.transaction do
          a = ShardRecord.connection
          note = ShardNote.create!(body: "on a")
          on(:b) do
            ShardRecord.transaction do
              note.after_commit_notice(on: a) { @calls << :sent }
              assert_nothing_enrolled_here
            end
          end
          assert_empty @calls, "B committed; A hasn't"
        end
      end

      assert_equal [:sent], @calls
    end

    test "queued from B on A's connection: dropped when A rolls back" do
      on(:a) do
        ShardRecord.transaction do
          a = ShardRecord.connection
          note = ShardNote.create!(body: "on a")
          on(:b) { note.after_commit_notice(on: a) { @calls << :sent } }
          assert_empty @calls, "B has no transaction, but the notice waits for A"
          raise ActiveRecord::Rollback
        end
      end

      assert_empty @calls
    end

    test "on a connection with no transaction open: sent at once, even inside B's" do
      a = on(:a) { ShardRecord.connection }
      note = on(:a) { ShardNote.create!(body: "on a") }

      on(:b) do
        ShardRecord.transaction do
          note.after_commit_notice(on: a) { @calls << :sent }
          assert_equal [:sent], @calls, "A has nothing to wait for; B's transaction isn't the notice's"
          assert_nothing_enrolled_here
        end
      end
    end

    test "without on:, the notice joins the class's connection at call time" do
      on(:a) do
        ShardRecord.transaction do
          ShardNote.create!(body: "on a").after_commit_notice { @calls << :sent }
          assert_empty @calls
        end
      end

      assert_equal [:sent], @calls
    end

    private

    def on(shard, &) = ShardRecord.connected_to(shard: shard, &)

    # The current connection's open transaction holds no Envelope.
    def assert_nothing_enrolled_here
      records = Array(ShardRecord.connection.current_transaction.records)
      assert records.none?(Moderate::DeferredNotices::Envelope), "no notice enrolled on this connection"
    end
  end

  # A gem decision whose report has a host after_save that switches the current
  # connection mid-save (stubbed here as the switch: the connection a notice would
  # default to is now shard B's; the model's own queries are left alone). The service
  # captured the report's connection before saving,
  # so its notices still join the primary database's transaction: sent at its commit,
  # never on its rollback, nothing on B.
  class DeferredNoticesHostSwitchTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    SWITCH = :moderate_test_switch_connection_mid_save

    setup do
      Moderate.configure do |config|
        config.audit = ->(event) { ModerateTestRecorder.audit(event) }
        config.notify = ->(event) { ModerateTestRecorder.notify(event) }
      end
      @b = ShardRecord.connected_to(shard: :b) { ShardRecord.connection }
      b = @b
      @switch = lambda do |_report|
        next unless Thread.current[SWITCH]

        Moderate::DeferredNotices.stubs(:connection_for).returns(b)
      end
      Moderate::Report.set_callback(:save, :after, @switch)
      author = User.create!(name: "Author", email: "a-switch@example.com")
      reporter = User.create!(name: "Reporter", email: "r-switch@example.com")
      comment = Comment.create!(user: author, body: "slur")
      @report = reporter.report!(comment, category: :hate, details: "x", field: :body)
      ModerateTestRecorder.clear
    end

    teardown do
      Thread.current[SWITCH] = nil
      Moderate::Report.skip_callback(:save, :after, @switch)
      [Moderate::Report, ::Comment, ::User].each(&:delete_all)
    end

    test "the decision's notices follow the connection captured before the save" do
      ActiveRecord::Base.transaction do
        Thread.current[SWITCH] = true
        @report.resolve!(by: User.create!(name: "Mod"), note: "Warned.")
        Thread.current[SWITCH] = nil
        assert_equal @b, Moderate::DeferredNotices.connection_for(Moderate::Report), "the host switched it"
        assert_empty ModerateTestRecorder.notifications, "nothing before the primary database commits"
        assert_not @b.current_transaction.open?, "and nothing on B"
      end

      assert_equal %i[affected_user_decision report_decision], ModerateTestRecorder.notifications.map(&:name).sort
    end

    test "and are dropped when the primary database rolls back" do
      ActiveRecord::Base.transaction do
        Thread.current[SWITCH] = true
        @report.resolve!(by: User.create!(name: "Mod"), note: "Warned.")
        Thread.current[SWITCH] = nil
        raise ActiveRecord::Rollback
      end

      assert_empty ModerateTestRecorder.notifications
    end
  end
end
