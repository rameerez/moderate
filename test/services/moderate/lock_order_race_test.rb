# frozen_string_literal: true

require "test_helper"

module Moderate
  # A comment a moderator can remove (its own base class, so a flag loads it back as itself).
  class LockOrderComment < ::ApplicationRecord
    self.table_name = "comments"

    belongs_to :user
    has_reportable_content :body

    def reported_owner = user

    def remove_reported_field!(field)
      field.to_s == "body" && update!(body: nil)
    end
  end

  # Test-only gates that hold a thread at a chosen point, so two decisions interleave
  # exactly as a race would. Inert unless the thread sets its gate.
  module LockOrderGates
    # Inside Flag#action!, holding the FLAG's lock, before it asks for the content's.
    module BeforeEnforce
      private

      def enforce!(...)
        LockOrderGates.pause(:before_enforce)
        super
      end
    end

    # Holding a lock taken by Moderate.with_row_lock on a LockOrderComment, before
    # the work inside it (flag_for_review!: before it looks for a waiting flag).
    module InsideContentLock
      def with_row_lock(record, &block)
        super(record) do
          LockOrderGates.pause(:inside_content_lock) if record.is_a?(LockOrderComment)
          block.call
        end
      end
    end

    def self.pause(point)
      gate = Thread.current[:moderate_lock_order_gate]
      return unless gate && gate[:at] == point

      Thread.current[:moderate_lock_order_gate] = nil
      gate[:arrived] << true
      gate[:go].pop
    end
  end
  Services::ResolveFlag.prepend(LockOrderGates::BeforeEnforce)
  Moderate.singleton_class.prepend(LockOrderGates::InsideContentLock)

  # The lock order (Moderate.with_row_lock): flag → content → person → report, on every
  # path. Real threads on real connections, so this test commits and cleans up after
  # itself. PostgreSQL and MySQL only: SQLite has no row locks.
  class LockOrderRaceTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      skip "SQLite has no row locks" if ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")

      tag = SecureRandom.hex(3)
      @moderator = User.create!(name: "Mod #{tag}")
      @admin = User.create!(name: "Admin #{tag}")
      @author = User.create!(name: "Author #{tag}")
      @comment = LockOrderComment.create!(user: @author, body: "slur")
      @flag = Moderate::Flag.flag!(
        flaggable: @comment, field: "body", owner: @author, source: "text_filter", mode: "flag",
        excerpt: "slur", categories: ["hate"], scores: {}, context: {}
      )
    end

    teardown do
      next unless @comment

      Moderate::Flag.where(flaggable_type: LockOrderComment.name, flaggable_id: @comment.id).delete_all
      Moderate::Report.where(reportable_type: LockOrderComment.name, reportable_id: @comment.id).delete_all
      @comment.destroy
      [@moderator, @admin, @author].each(&:destroy)
    end

    test "enforcement holds the flag, then a review of the same content arrives: no deadlock" do
      enforcing = gated(:before_enforce) do
        Moderate::Flag.find(@flag.id).action!(by: @moderator, note: "Slur.", remove_content: true)
      end
      enforcing[:arrived].pop # holds the flag, hasn't asked for the content yet

      reviewing = in_thread { Moderate::Flag.flag_for_review!(LockOrderComment.find(@comment.id), field: :body, by: @admin) }
      sleep 0.2 # the review takes the content lock and reads, while enforcement holds the flag
      enforcing[:go] << :go

      assert_nothing_raised { [enforcing[:thread], reviewing].each(&:join) }
      assert_equal "actioned", @flag.reload.status
      assert_nil @comment.reload.body, "removed"
    end

    test "a review holds the content, then enforcement of the same content's flag arrives: no deadlock" do
      reviewing = gated(:inside_content_lock) do
        Moderate::Flag.flag_for_review!(LockOrderComment.find(@comment.id), field: :body, by: @admin)
      end
      reviewing[:arrived].pop # holds the content, hasn't looked for a waiting flag yet

      enforcing = in_thread do
        Moderate::Flag.find(@flag.id).action!(by: @moderator, note: "Slur.", remove_content: true)
      end
      sleep 0.2 # enforcement takes the flag and waits for the content
      reviewing[:go] << :go

      assert_nothing_raised { [reviewing[:thread], enforcing].each(&:join) }
      assert_equal "actioned", @flag.reload.status
      assert_equal @flag, reviewing[:thread].value, "the review found the flag already waiting"
    end

    test "removal-only enforcement never waits on the person's row" do
      holding = Queue.new
      release = Queue.new
      holder = in_thread do
        User.transaction do
          User.lock.find(@author.id) # someone else holds the account's row
          holding << true
          release.pop
        end
      end
      holding.pop

      enforcing = in_thread do
        Moderate::Flag.find(@flag.id).action!(by: @moderator, note: "Slur.", remove_content: true)
      end
      finished = enforcing.join(5)
      release << :go
      holder.join

      assert finished, "removal-only enforcement blocked on the person's lock"
      assert_equal "actioned", @flag.reload.status
    end

    private

    def in_thread(&block)
      Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
    end

    # Run `block` on its own thread and connection, pausing it at `point`.
    def gated(point, &block)
      gate = { at: point, arrived: Queue.new, go: Queue.new }
      gate[:thread] = Thread.new do
        Thread.current[:moderate_lock_order_gate] = gate
        ActiveRecord::Base.connection_pool.with_connection(&block)
      end
      gate
    end
  end
end
