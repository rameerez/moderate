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

  # A notice follows the connection its record was saved on (Moderate::DeferredNotices):
  # saved on shard A inside A's transaction, it is sent when A commits and dropped when
  # A rolls back — even when it is queued from inside a `connected_to` block on shard
  # B, and even when B has a transaction of its own. Nothing is enrolled on B.
  class DeferredNoticesShardsTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      %i[a b].each do |shard|
        ShardRecord.connected_to(shard: shard) do
          ShardRecord.connection.create_table(:moderate_shard_notes, force: true) { |t| t.string :body }
        end
      end
      @calls = []
    end

    teardown do
      %i[a b].each do |shard|
        on(shard) { ShardRecord.connection.drop_table(:moderate_shard_notes, if_exists: true) }
      end
    end

    test "saved on A, queued from B: sent when A commits, not when B does" do
      on(:a) do
        ShardRecord.transaction do
          note = ShardNote.create!(body: "on a")
          on(:b) do
            ShardRecord.transaction do
              note.after_commit_notice { @calls << :sent }
              assert_nothing_enrolled_here
            end
          end
          assert_empty @calls, "B committed; A hasn't"
        end
      end

      assert_equal [:sent], @calls
    end

    test "saved on A, queued from B: dropped when A rolls back" do
      on(:a) do
        ShardRecord.transaction do
          note = ShardNote.create!(body: "on a")
          on(:b) { note.after_commit_notice { @calls << :sent } }
          assert_empty @calls, "B has no transaction, but the notice waits for A"
          raise ActiveRecord::Rollback
        end
      end

      assert_empty @calls
    end

    test "saved on A with no transaction open there, queued inside B's: sent at once" do
      note = on(:a) { ShardNote.create!(body: "on a") }

      on(:b) do
        ShardRecord.transaction do
          note.after_commit_notice { @calls << :sent }
          assert_equal [:sent], @calls, "A has nothing to wait for; B's transaction isn't the record's"
          assert_nothing_enrolled_here
        end
      end
    end

    test "on one shard, the rules are the usual ones" do
      on(:a) do
        ShardRecord.transaction do
          ShardNote.create!(body: "on a").after_commit_notice { @calls << :sent }
          assert_empty @calls
        end
      end

      assert_equal [:sent], @calls
    end

    private

    def on(shard, &block) = ShardRecord.connected_to(shard: shard, &block)

    # The current connection's open transaction holds no Envelope.
    def assert_nothing_enrolled_here
      records = Array(ShardRecord.connection.current_transaction.records)
      assert records.none?(Moderate::DeferredNotices::Envelope), "no notice enrolled on this connection"
    end
  end
end
