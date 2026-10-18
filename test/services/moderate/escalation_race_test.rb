# frozen_string_literal: true

require "test_helper"

module Moderate
  # Content whose removals are counted across threads.
  class RaceComment < ::ApplicationRecord
    self.table_name = "comments"

    belongs_to :user
    has_reportable_content :body

    REMOVALS = Queue.new

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

      Moderate::Flag.where(id: @flags.map(&:id)).delete_all
      Moderate::Report.where(reportable_type: RaceComment.name, reportable_id: @comment.id).delete_all
      @comment.destroy
      [*@moderators, @author].each(&:destroy)
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
  end
end
