# frozen_string_literal: true

require "test_helper"
require_relative "../../support/lock_waits"

module Moderate
  # Content whose removals are counted across threads.
  class RaceComment < ::ApplicationRecord
    self.table_name = "comments"

    belongs_to :user
    has_reportable_content :body

    REMOVALS = Queue.new
    BANS = Queue.new

    def reported_owner = user

    def remove_reported_field!(field)
      return false unless field.to_s == "body"

      update!(body: nil)
      REMOVALS << id
      true
    end
  end

  # Concurrent enforcement through Flag#action!: two moderators on one flag, two flags
  # on different fields of one record, two flags on different content of one person.
  # The locks (flag → content → person → report, Moderate.with_row_lock) serialize
  # them, and the checks made under them are locking reads, so content is removed
  # once and a person banned once. Real threads on real connections, released only
  # once the database shows each one waiting on a lock (LockWaits), so this test
  # commits and cleans up after itself. PostgreSQL and MySQL only: SQLite has no row
  # locks.
  class EscalationRaceTest < ActiveSupport::TestCase
    include LockWaits

    self.use_transactional_tests = false

    setup do
      skip "SQLite has no row locks" if ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")

      RaceComment::REMOVALS.clear
      RaceComment::BANS.clear
      Moderate.configure { |config| config.ban_handler = ->(user:, **) { RaceComment::BANS << user.id } }
      tag = SecureRandom.hex(3)
      @moderators = 2.times.map { |n| User.create!(name: "Mod #{n} #{tag}") }
      @author = User.create!(name: "Author #{tag}")
      @comment = RaceComment.create!(user: @author, body: "slur")
      @flag = file_flag(@comment, "body")
    end

    teardown do
      next unless @comment

      Moderate::Flag.where(owner_id: @author.id).delete_all
      Moderate::Report.where(reportable_type: RaceComment.name).delete_all
      RaceComment.where(user_id: @author.id).delete_all
      [*@moderators, @author].each(&:destroy)
    end

    test "two moderators enforcing one flag at once remove it once" do
      race([[@flag, { remove_content: true }], [@flag, { remove_content: true }]], holding: @comment)

      assert_equal 1, RaceComment::REMOVALS.size, "removed once"
      reports = Moderate::Report.where(reportable_type: RaceComment.name, reportable_id: @comment.id)
      assert_equal 1, reports.count, "one decision"
      assert_equal "actioned", @flag.reload.status
      assert_equal reports.sole.id, @flag.context["report_id"]
    end

    test "two flags on different fields of one record, banning at once, ban the person once" do
      image_flag = file_flag(@comment, "image")

      race([[@flag, { ban_user: true }], [image_flag, { ban_user: true }]], holding: @comment)

      assert_equal 1, RaceComment::BANS.size, "one ban"
      noted = Moderate::Report.where(reportable_type: RaceComment.name).map { |r| r.resolution_actions["ban_already_applied_by"] }
      assert_equal 1, noted.compact.size, "the other decision says which one banned"
    end

    test "two flags on different content of one person, banning at once, ban the person once" do
      other_flag = file_flag(RaceComment.create!(user: @author, body: "more"), "body")

      race([[@flag, { ban_user: true }], [other_flag, { ban_user: true }]], holding: @author)

      assert_equal 1, RaceComment::BANS.size, "the person's row lock serializes bans across content"
    end

    private

    def file_flag(content, field)
      Moderate::Flag.flag!(
        flaggable: content, field: field, owner: @author, source: "text_filter", mode: "flag",
        excerpt: "slur", categories: ["hate"], scores: {}, context: {}
      )
    end

    # Run each [flag, keywords] decision on its own thread and connection while
    # `holding`'s row is locked here, and release that lock only once the database
    # shows both of them waiting on a lock: neither may decide before both are in line.
    def race(decisions, holding:)
      ids = Queue.new
      go = Queue.new
      threads = decisions.zip(@moderators).map do |(flag, options), moderator|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ids << backend_id
            go.pop
            Moderate::Flag.find(flag.id).action!(by: moderator, note: "Abuse.", **options)
          end
        end
      end
      backends = decisions.map { ids.pop }

      Moderate.with_row_lock(holding.class.find(holding.id)) do
        decisions.size.times { go << :go }
        backends.each { |id| wait_until_blocked(id) }
      end
      threads.each(&:join)
    end
  end
end
