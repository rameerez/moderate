# frozen_string_literal: true

require "test_helper"

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

  # Two moderators enforcing two DIFFERENT flags on the SAME content at once
  # (Flag#action!, remove_content: true). Each holds its own flag's lock, so only the
  # content's row lock can serialize them: the first removes, the second waits, then
  # closes against the first decision. Without it both open a system report and
  # remove twice. Real threads on real connections, so this test commits and cleans
  # up after itself. PostgreSQL and MySQL only: SQLite has no row locks.
  class EscalationRaceTest < ActiveSupport::TestCase
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
      @flags = %w[text_filter manual].map do |source|
        Moderate::Flag.flag!(
          flaggable: @comment, field: "body", owner: @author, source: source, mode: "flag",
          excerpt: "slur", categories: ["hate"], scores: {}, context: {}
        )
      end
    end

    teardown do
      next unless @comment

      Moderate::Flag.where(id: (@flags + Array(@more_flags)).map(&:id)).delete_all
      Moderate::Report.where(reportable_type: RaceComment.name).delete_all
      RaceComment.where(user_id: @author.id).delete_all
      [*@moderators, @author].each(&:destroy)
    end

    # Run each [flag, keywords] decision on its own thread and connection, released
    # together while `lock_holder`'s row is held, so neither may look before both wait.
    def race(decisions, lock_holder)
      gate = Queue.new
      threads = decisions.zip(@moderators).map do |(flag, options), moderator|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            Moderate::Flag.find(flag.id).action!(by: moderator, note: "Abuse.", **options)
          end
        end
      end
      lock_holder.with_lock do
        decisions.size.times { gate << :go }
        sleep 0.2
      end
      threads.each(&:join)
    end

    test "two flags on one content, enforced at once, remove it once" do
      gate = Queue.new
      threads = @flags.zip(@moderators).map do |flag, moderator|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            Moderate::Flag.find(flag.id).action!(by: moderator, note: "Slur.", remove_content: true)
          end
        end
      end
      # Hold the content's row so both arrive before either may decide.
      @comment.with_lock do
        2.times { gate << :go }
        sleep 0.2
      end
      threads.each(&:join)

      assert_equal 1, RaceComment::REMOVALS.size, "removed once"
      reports = Moderate::Report.where(reportable_type: RaceComment.name, reportable_id: @comment.id)
      assert_equal 1, reports.count, "one decision"
      assert_equal %w[actioned actioned], Moderate::Flag.where(id: @flags.map(&:id)).pluck(:status)
      report_ids = Moderate::Flag.where(id: @flags.map(&:id)).map { |flag| flag.context["report_id"] }
      assert_equal [reports.sole.id], report_ids.uniq
    end

    test "two flags on different fields of one record, banning at once, ban the person once" do
      image_flag = Moderate::Flag.flag!(
        flaggable: @comment, field: "image", owner: @author, source: "manual", mode: "flag",
        excerpt: nil, categories: [], scores: {}, context: {}
      )
      @more_flags = [image_flag]

      race([[@flags.first, { ban_user: true }], [image_flag, { ban_user: true }]], @comment)

      assert_equal 1, RaceComment::BANS.size, "one ban"
      noted = Moderate::Report.where(reportable_type: RaceComment.name).map { |r| r.resolution_actions["ban_already_applied_by"] }
      assert_equal 1, noted.compact.size, "the other decision says which one banned"
    end

    test "two flags on different content of one person, banning at once, ban the person once" do
      other = RaceComment.create!(user: @author, body: "more")
      other_flag = Moderate::Flag.flag!(
        flaggable: other, field: "body", owner: @author, source: "text_filter", mode: "flag",
        excerpt: "more", categories: ["hate"], scores: {}, context: {}
      )
      @more_flags = [other_flag]

      race([[@flags.first, { ban_user: true }], [other_flag, { ban_user: true }]], @author)

      assert_equal 1, RaceComment::BANS.size, "the person's row lock serializes bans across content"
    end
  end
end
