# frozen_string_literal: true

require "test_helper"
require_relative "../../support/lock_waits"

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

    # Inside Flag.flag! after a collision, holding the waiting flag's lock (it was
    # just read FOR UPDATE), before returning it.
    module AfterWaitingFlagRead
      private

      def waiting_flag(key)
        super.tap { LockOrderGates.pause(:after_waiting_flag_read) }
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
  Flag.singleton_class.prepend(LockOrderGates::AfterWaitingFlagRead)

  # The lock order (Moderate.with_row_lock): flag → content → person → report, on every
  # path, so a review and an enforcement of the same content never deadlock, and
  # removal-only enforcement never touches the person. Real threads on real
  # connections, each step released only once the database shows the other side
  # waiting on a lock (LockWaits), so this test commits and cleans up after itself.
  # PostgreSQL and MySQL only: SQLite has no row locks.
  class LockOrderRaceTest < ActiveSupport::TestCase
    include LockWaits

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

    # On MySQL this is also the deadlock Flag.flag! retries: the review's duplicate
    # check waits on the flag's key, whose index entry the closing UPDATE moves into
    # the very gap that check has queued a lock on; InnoDB rolls the review back.
    test "enforcement holds the flag when a review of the same content arrives: the review waits, then files anew" do
      enforcing = gated(:before_enforce) do
        Moderate::Flag.find(@flag.id).action!(by: @moderator, note: "Slur.", remove_content: true)
      end
      enforcing[:arrived].pop # holds the flag, hasn't asked for the content yet

      reviewing = gated(nil) { Moderate::Flag.flag_for_review!(LockOrderComment.find(@comment.id), field: :body, by: @admin) }
      released(enforcing) { wait_until_blocked(reviewing[:backend].pop) } # its insert collided; it waits on the flag

      assert_nothing_raised { [enforcing, reviewing].each { |side| side[:thread].join } }
      assert_equal "actioned", @flag.reload.status
      assert_nil @comment.reload.body, "removed"
      filed = reviewing[:thread].value
      assert_not_equal @flag, filed, "the decided flag freed the field: the review filed a new one"
      assert_predicate filed, :pending?
    end

    test "a review holds the waiting flag when enforcement of it arrives: enforcement waits, then decides" do
      reviewing = gated(:after_waiting_flag_read) do
        Moderate::Flag.transaction do # holds the waiting flag's lock until its transaction ends
          Moderate::Flag.flag_for_review!(LockOrderComment.find(@comment.id), field: :body, by: @admin)
        end
      end
      reviewing[:arrived].pop

      enforcing = gated(nil) { Moderate::Flag.find(@flag.id).action!(by: @moderator, note: "Slur.", remove_content: true) }
      released(reviewing) { wait_until_blocked(enforcing[:backend].pop) } # on the flag the review holds

      assert_nothing_raised { [reviewing, enforcing].each { |side| side[:thread].join } }
      assert_equal @flag, reviewing[:thread].value, "the review found the flag already waiting"
      assert_equal "actioned", @flag.reload.status
    end

    test "removal-only enforcement never waits on the person's row" do
      holding = Queue.new
      release = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User.transaction do
            User.lock.find(@author.id) # someone else holds the account's row
            holding << true
            release.pop
          end
        end
      end
      holding.pop

      begin
        enforcing = gated(nil) { Moderate::Flag.find(@flag.id).action!(by: @moderator, note: "Slur.", remove_content: true) }
        finished = enforcing[:thread].join(5)
      ensure
        release << :go # whatever happened, the holder lets go of the account's row
        holder.join
      end

      assert finished, "removal-only enforcement blocked on the person's lock"
      assert_equal "actioned", @flag.reload.status
    end

    private

    # Run the block, then let the gated thread go on, whatever happened: a failure
    # must never leave a transaction parked with its locks held.
    def released(gate)
      yield
    ensure
      gate[:go] << :go
    end

    # Run `block` on its own thread and connection, reporting its backend id, and
    # pausing it at `point` (nil: no pause).
    def gated(point, &block)
      gate = { at: point, arrived: Queue.new, go: Queue.new, backend: Queue.new }
      gate[:thread] = Thread.new do
        Thread.current[:moderate_lock_order_gate] = gate if point
        ActiveRecord::Base.connection_pool.with_connection do
          gate[:backend] << backend_id
          block.call
        end
      end
      gate
    end
  end
end
