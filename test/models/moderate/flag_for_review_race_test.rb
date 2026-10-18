# frozen_string_literal: true

require "test_helper"
require_relative "../../support/lock_waits"

module Moderate
  # Two filings of "Flag for review" on one record at once
  # (Moderate::Flag.flag_for_review!). At most one flag may be pending per content and
  # field, and the database says so (the unique pending_key): one filing inserts, the
  # other's insert collides and returns the flag already waiting. Real threads on real
  # connections, so this test commits and cleans up after itself.
  #
  # PostgreSQL and MySQL only: SQLite serializes writers and has no row locks, so
  # there is no interleaving to force on it.
  class FlagForReviewRaceTest < ActiveSupport::TestCase
    include LockWaits

    self.use_transactional_tests = false

    setup do
      skip "SQLite has no row locks" if ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")

      tag = SecureRandom.hex(3)
      @admins = 2.times.map { |n| User.create!(name: "Admin #{n} #{tag}") }
      @author = User.create!(name: "Author #{tag}")
      @comment = Comment.create!(user: @author, body: "see you on the ladder")
    end

    teardown do
      next unless @comment

      Moderate::Flag.where(flaggable: @comment).delete_all
      @comment.destroy
      [*@admins, @author].each(&:destroy)
    end

    test "two at once file one flag: the second waits on the first's insert, then gets it" do
      ids = Queue.new
      inserted = Queue.new
      commit = Queue.new

      first = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Moderate::Flag.transaction do # holds its uncommitted insert until told
            flag = Moderate::Flag.flag_for_review!(Comment.find(@comment.id), field: :body, by: @admins[0])
            inserted << true
            commit.pop
            flag
          end
        end
      end
      inserted.pop

      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ids << backend_id
          Moderate::Flag.flag_for_review!(Comment.find(@comment.id), field: :body, by: @admins[1])
        end
      end
      wait_until_blocked(ids.pop) # on the first's uncommitted, unique pending_key
      commit << :go

      filed = first.value
      joined = second.value
      assert_predicate filed, :previously_new_record?
      assert_equal filed, joined
      assert_not_predicate joined, :previously_new_record?
      assert_equal 1, Moderate::Flag.pending.where(flaggable: @comment).count
    end

    # The sequence that defeated a plain read under the content lock on MySQL
    # (REPEATABLE READ): A's transaction makes a consistent read first, so its snapshot
    # predates B's flag; B files and commits; then A files. The insert collides with
    # what is committed, whatever A's snapshot, and the waiting flag is read with a
    # locking read, which returns the latest committed row.
    test "a filing whose transaction already read gets the flag committed since, not a second one" do
      read = Queue.new
      filed_by_b = Queue.new

      a = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Moderate::Flag.transaction do
            Moderate::Flag.where(flaggable: @comment).to_a # the consistent read: A's snapshot starts here
            read << true
            filed_by_b.pop
            Moderate::Flag.flag_for_review!(Comment.find(@comment.id), field: :body, by: @admins[0])
          end
        end
      end
      read.pop

      b = ActiveRecord::Base.connection_pool.with_connection do
        Moderate::Flag.flag_for_review!(Comment.find(@comment.id), field: :body, by: @admins[1])
      end
      filed_by_b << b

      got = a.value
      assert_equal b, got, "A gets B's flag"
      assert_not_predicate got, :previously_new_record?
      assert_equal 1, Moderate::Flag.where(flaggable: @comment, field: "body").count, "no second row"
    end
  end
end
