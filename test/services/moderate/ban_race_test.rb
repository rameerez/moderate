# frozen_string_literal: true

require "test_helper"

module Moderate
  # Two ban decisions on the same person at once, with a ban state the host keeps in
  # the database (`config.banned` reads `users.suspended_at`): the second waits for the
  # person's lock, then reads the person again under it, sees the first one's ban, and
  # records `ban_already_applied_by` instead of calling the ban_handler a second time,
  # even inside a host transaction whose earlier read pinned an older snapshot (MySQL).
  # Real threads on real connections, so this test commits and cleans up after itself.
  #
  # PostgreSQL and MySQL only: SQLite has no row locks.
  class BanRaceTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      skip "SQLite has no row locks" if ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")

      @calls = Concurrent::AtomicFixnum.new
      calls = @calls
      Moderate.configure do |config|
        config.banned = ->(user) { user.suspended_at.present? }
        config.ban_handler = lambda do |user:, **|
          calls.increment
          sleep 0.2 # the second decision is waiting on the person's lock meanwhile
          user.update_columns(suspended_at: Time.current)
        end
      end
      tag = SecureRandom.hex(3)
      @moderators = 2.times.map { |n| User.create!(name: "Mod #{n} #{tag}") }
      @author = User.create!(name: "Author #{tag}", email: "author-#{tag}@example.com")
      @reporter = User.create!(name: "Reporter #{tag}", email: "reporter-#{tag}@example.com")
      @reports = 2.times.map do |n|
        @reporter.report!(Comment.create!(user: @author, body: "post #{n}"), category: :harassment, field: :body)
      end
    end

    teardown do
      next unless @reports

      Moderate::Report.where(id: @reports.map(&:id)).delete_all
      Comment.where(user: @author).delete_all
      [*@moderators, @author, @reporter].each(&:destroy)
    end

    test "two ban decisions on one person at once call the ban_handler once" do
      gate = Queue.new
      threads = @reports.zip(@moderators).map do |report, moderator|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            # A host's own transaction that read the person before deciding: on MySQL
            # (REPEATABLE READ) that read pins the snapshot every later plain read sees.
            ActiveRecord::Base.transaction do
              fresh = Moderate::Report.find(report.id)
              User.find(@author.id).suspended_at
              gate.pop
              fresh.resolve!(by: moderator, note: "Harassment", ban_user: true)
            end
          end
        end
      end
      # Hold the person's row so both decisions are under way before either may ban.
      @author.with_lock do
        2.times { gate << :go }
        sleep 0.2
      end
      threads.each(&:join)

      assert_equal 1, @calls.value, "one ban"
      covered = Moderate::Report.where(id: @reports.map(&:id)).map { |r| r.resolution_actions["ban_already_applied_by"] }
      assert_equal 1, covered.compact.size, "the second records the first"
      assert_predicate @author.reload.suspended_at, :present?
    end
  end
end
