# frozen_string_literal: true

require "test_helper"

module Moderate
  # Two administrators pressing "Flag for review" on one record at once
  # (Moderate::Flag.flag_for_review!): the check and the insert run under the record's
  # row lock, so one flag is filed and the other gets it back. Real threads on real
  # connections, so this test commits and cleans up after itself. (Ported from
  # playscbw's Admin::ReviewFlag race test, which this API replaces.)
  #
  # PostgreSQL and MySQL only: SQLite has no row locks (SELECT ... FOR UPDATE is a
  # no-op there), so there is nothing for this test to prove on it.
  class FlagForReviewRaceTest < ActiveSupport::TestCase
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

    test "two at once file one flag" do
      gate = Queue.new
      threads = @admins.map do |admin|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            Moderate::Flag.flag_for_review!(Comment.find(@comment.id), field: :body, by: admin).previously_new_record?
          end
        end
      end
      # Hold the row so both arrive before either may look: without the lock both
      # would find no flag and both would file one.
      @comment.with_lock do
        2.times { gate << :go }
        sleep 0.2
      end

      assert_equal [false, true], threads.map(&:value).sort_by { |created| created ? 1 : 0 }
      assert_equal 1, Moderate::Flag.pending.where(flaggable: @comment).count
    end
  end
end
