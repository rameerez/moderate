# frozen_string_literal: true

require "test_helper"

module Moderate
  # Tests for Moderate::Block — the bidirectional safety edge behind every "block"
  # feature and behind Moderate.blocked_ids_for.
  #
  # Ported from the reference suite (test/models/moderation/block_test.rb) and
  # de-host-ified: the host concepts (drivers, listings, join-request cancellation)
  # are gone, and assertions are realigned to the GEM's actual API — the SSOT method
  # is `related_user_ids` (not the reference's `user_ids_related_to`), and the
  # audit/notify payloads carry `:blocker_id`/`:blocked_id` (not whole records).
  #
  # NOTE on hooks: test_helper's `setup` resets config to ONLY `user_class = "User"`,
  # so audit/notify/on_block default to no-ops. Any test that asserts on dispatched
  # events must re-point the hooks itself (we capture into a local array). This keeps
  # each test honest about which hooks it exercises.
  class BlockTest < ActiveSupport::TestCase
    setup do
      @blocker = create_user
      @blocked = create_user
    end

    test "block! is idempotent — re-blocking the same edge is a no-op" do
      # find_or_initialize means the second call returns the existing row without
      # creating a duplicate (the DB unique index would reject one anyway).
      assert_difference -> { Moderate::Block.count }, 1 do
        Moderate::Block.block!(blocker: @blocker, blocked: @blocked)
        Moderate::Block.block!(blocker: @blocker, blocked: @blocked)
      end
    end

    test "block! audits and notifies :user_blocked ONLY on a real (new) block" do
      audits = []
      notifications = []
      Moderate.config.audit = ->(event) { audits << event }
      Moderate.config.notify = ->(event) { notifications << event; true }

      # First call creates the edge → one audit + one notify; second is a no-op.
      Moderate::Block.block!(blocker: @blocker, blocked: @blocked)
      Moderate::Block.block!(blocker: @blocker, blocked: @blocked)

      assert_equal [:user_blocked], audits.map(&:name)
      assert_equal [:user_blocked], notifications.map(&:name)
      # Payloads carry the ids (host-agnostic — never the full record).
      assert_equal @blocker.id, notifications.first.payload[:blocker_id]
      assert_equal @blocked.id, notifications.first.payload[:blocked_id]
    end

    test "block! fires the on_block side-effect hook once on creation" do
      captured = []
      Moderate.config.on_block = ->(blocker:, blocked:) { captured << [blocker, blocked] }

      Moderate::Block.block!(blocker: @blocker, blocked: @blocked)
      Moderate::Block.block!(blocker: @blocker, blocked: @blocked)

      assert_equal [[@blocker, @blocked]], captured
    end

    test "unblock! removes the edge and returns true; missing edge returns false" do
      Moderate::Block.block!(blocker: @blocker, blocked: @blocked)

      assert_difference -> { Moderate::Block.count }, -1 do
        assert_equal true, Moderate::Block.unblock!(blocker: @blocker, blocked: @blocked)
      end
      # Calling again with nothing to remove is safe and reports "nothing happened".
      assert_equal false, Moderate::Block.unblock!(blocker: @blocker, blocked: @blocked)
    end

    test "a user cannot block themselves (model validation mirrors the DB CHECK)" do
      block = Moderate::Block.new(blocker: @blocker, blocked: @blocker)

      refute block.valid?
      assert block.errors[:blocked].any?
    end

    test "blocking the same pair twice is rejected by the uniqueness validation" do
      Moderate::Block.create!(blocker: @blocker, blocked: @blocked)
      dup = Moderate::Block.new(blocker: @blocker, blocked: @blocked)

      refute dup.valid?
      assert dup.errors[:blocked_id].any?
    end

    test "related_user_ids includes BOTH block directions (the bidirectional SSOT)" do
      viewer = create_user
      blocked_by_viewer = create_user # viewer blocked them
      blocking_viewer = create_user   # they blocked viewer

      Moderate::Block.block!(blocker: viewer, blocked: blocked_by_viewer)
      Moderate::Block.block!(blocker: blocking_viewer, blocked: viewer)

      # Returns an AR relation of user ids; both directions show up.
      assert_equal [blocked_by_viewer.id, blocking_viewer.id].sort,
        Moderate::Block.related_user_ids(viewer).pluck(:id).sort
    end

    test "related_user_ids is empty for a blank user" do
      assert_empty Moderate::Block.related_user_ids(nil).pluck(:id)
    end

    test "Moderate.blocked_ids_for delegates to Block.related_user_ids" do
      viewer = create_user
      other = create_user
      Moderate::Block.block!(blocker: viewer, blocked: other)

      ids = Moderate.blocked_ids_for(viewer).pluck(:id)
      assert_equal [other.id], ids
      # The facade returns [] (not a relation) for a nil user, so a `where.not` over
      # it is always safe even with no current user.
      assert_equal [], Moderate.blocked_ids_for(nil)
    end

    test "between scope finds the edge in either direction" do
      Moderate::Block.block!(blocker: @blocker, blocked: @blocked)

      assert Moderate::Block.between(@blocker, @blocked).exists?
      assert Moderate::Block.between(@blocked, @blocker).exists?
      assert_empty Moderate::Block.between(@blocker, create_user)
    end

    private

    # The dummy actor model (config.user_class). A sequenced name keeps the
    # :flag-moderated `name` field clean so creating a user never trips the wordlist.
    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end
  end
end
