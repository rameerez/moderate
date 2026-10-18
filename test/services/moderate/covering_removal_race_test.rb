# frozen_string_literal: true

require "test_helper"

module Moderate
  # A report filed while another decision on the same content is removing it: B's
  # intake commits while A holds the content's lock and hasn't stamped yet. B saw the
  # committed (not yet removed) text, so A's stamping read finds it with that text and
  # stamps it, truthfully: B is about the content A removed. Never a false cover: a
  # report that is stamped carries A's text, and one that isn't is refused.
  # Real threads on real connections, so this test commits and cleans up after itself.
  #
  # PostgreSQL and MySQL only: SQLite has no row locks.
  class CoveringRemovalRaceTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      skip "SQLite has no row locks" if ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")

      tag = SecureRandom.hex(3)
      @moderator = User.create!(name: "Mod #{tag}")
      @author = User.create!(name: "Author #{tag}", email: "author-#{tag}@example.com")
      @reporters = 2.times.map { |n| User.create!(name: "Reporter #{n} #{tag}", email: "r#{n}-#{tag}@example.com") }
      @comment = Comment.create!(user: @author, body: "vile words")
      @first = @reporters.first.report!(@comment, category: :harassment, field: :body)
    end

    teardown do
      next unless @comment

      Moderate::Report.where(reportable: @comment).or(Moderate::Report.where(id: [@first&.id, @late&.id])).delete_all
      Comment.where(id: @comment.id).delete_all
      [@moderator, @author, *@reporters].each(&:destroy)
    end

    test "a report filed during the removal is stamped with the text it saw, or refused; never falsely covered" do
      inside = Queue.new
      filed = Queue.new
      comment = Comment.find(@comment.id)
      comment.define_singleton_method(:remove_reported_field!) do |_field|
        update_column(:body, "") # uncommitted until the decision commits
        inside << :removing
        filed.pop # wait for the other report to be filed and committed
        true
      end
      first = Moderate::Report.find(@first.id)
      first.stubs(:reportable).returns(comment)

      decision = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          first.resolve!(by: @moderator, note: "Harassment", remove_content: true)
        end
      end
      inside.pop
      reporter = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          @late = @reporters.last.report!(Comment.find(@comment.id), category: :harassment, field: :body)
        end
      end
      reporter.join
      filed << :go
      decision.join

      @late.reload
      if @late.covered_by_report_id
        assert_equal @first.id, @late.covered_by_report_id
        assert_equal "vile words", @late.snapshot["content_text"], "stamped only with the text that was removed"
        @late.resolve!(by: @moderator, note: "Same content", remove_content: true)
        assert_equal @first.id, @late.reload.resolution_actions["content_already_removed_by"]
      else
        error = assert_raises(ActiveRecord::RecordInvalid) do
          @late.resolve!(by: @moderator, note: "Same content", remove_content: true)
        end
        assert_match "Nothing was removed", error.message
      end
    end
  end
end
