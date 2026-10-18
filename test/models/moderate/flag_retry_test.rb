# frozen_string_literal: true

require "test_helper"

module Moderate
  # Flag.flag!'s retries, with the failures injected: a deadlock it owns is tried
  # again, and when the attempts run out the LAST failure is raised as it was, a
  # deadlock as ActiveRecord::Deadlocked. Not transactional: a retry needs flag! to
  # own its transaction, as it does in the filters' after_commit and ClassifyJob.
  class FlagRetryTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    # Fails Flag.create! with `error`, `left` more times, then lets it through.
    module FailingCreate
      class << self
        attr_accessor :error, :left, :tries
      end
      self.left = 0
      self.tries = 0

      def create!(*, **, &)
        FailingCreate.tries += 1
        if FailingCreate.left.positive?
          FailingCreate.left -= 1
          raise FailingCreate.error, "injected by the test"
        end
        super
      end
    end
    Moderate::Flag.singleton_class.prepend(FailingCreate)

    setup do
      @user = User.create!(name: "Retry #{SecureRandom.hex(3)}", email: "retry-#{SecureRandom.hex(4)}@example.com")
      FailingCreate.tries = 0
    end

    teardown do
      FailingCreate.left = 0
      Moderate::Flag.where(flaggable: @user).delete_all
      @user.destroy
    end

    test "deadlocked three times: ActiveRecord::Deadlocked, not a uniqueness error" do
      failing(ActiveRecord::Deadlocked, 3)

      assert_raises(ActiveRecord::Deadlocked) { file }
      assert_equal 3, FailingCreate.tries
      assert_equal 0, Moderate::Flag.where(flaggable: @user).count
    end

    test "deadlocked twice, filed on the third try" do
      failing(ActiveRecord::Deadlocked, 2)

      flag = file
      assert_predicate flag, :previously_new_record?
      assert_equal 3, FailingCreate.tries
    end

    test "inside the caller's transaction a deadlock is raised at once, for the caller to retry" do
      failing(ActiveRecord::Deadlocked, 1)

      assert_raises(ActiveRecord::Deadlocked) { Moderate::Flag.transaction { file } }
      assert_equal 1, FailingCreate.tries
    end

    test "a collision with no pending flag to join, three times: ActiveRecord::RecordNotUnique" do
      failing(ActiveRecord::RecordNotUnique, 3)
      Moderate::Flag.stubs(:waiting_flag).returns(nil) # decided each time before it was read

      assert_raises(ActiveRecord::RecordNotUnique) { file }
      assert_equal 3, FailingCreate.tries
    end

    private

    def failing(error, times)
      FailingCreate.error = error
      FailingCreate.left = times
    end

    def file
      Moderate::Flag.flag!(
        flaggable: @user, field: "name", owner: nil, source: "manual", mode: "flag",
        excerpt: nil, categories: [], scores: {}, context: {}
      )
    end
  end
end
