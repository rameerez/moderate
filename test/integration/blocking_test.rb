# frozen_string_literal: true

require "test_helper"

# Blocking enforcement, end-to-end, driven through the dummy host's User (actor) and
# Comment (content) models — no host specifics, just "two users, one block edge, and
# the SSOT query a host uses to hide them from each other."
#
# The point of this file is the property the README sells as the whole reason the
# block table exists: a block is DIRECTED in storage but BIDIRECTIONAL in effect, and
# a host enforces it everywhere with ONE query:
#
#   Post.where.not(user_id: Moderate.blocked_ids_for(current_user))
#
# So we assert both the predicate API (blocks?/blocked_by?/blocked_with?) and, most
# importantly, that `Moderate.blocked_ids_for` (the SSOT behind that query) sees BOTH
# directions and actually filters host content. Apple Guideline 1.2(c) and Google Play
# UGC both require an in-app block mechanism; this is the behavior that satisfies it.
class BlockingTest < ActiveSupport::TestCase
  setup do
    @alice = User.create!(name: "Alice", email: "alice@example.com")
    @bob = User.create!(name: "Bob", email: "bob@example.com")
    @carol = User.create!(name: "Carol", email: "carol@example.com")
    ModerateTestRecorder.clear
    rewire_hooks
  end

  # --- The block edge + predicates --------------------------------------------

  test "block! creates one directed edge and the predicates read both directions" do
    assert_difference -> { Moderate::Block.count }, 1 do
      @alice.block!(@bob)
    end

    # Alice -> Bob direction.
    assert @alice.blocks?(@bob), "alice blocked bob"
    refute @alice.blocked_by?(@bob), "bob hasn't blocked alice"

    # Bob sees the edge from the other side.
    refute @bob.blocks?(@alice), "bob didn't initiate a block"
    assert @bob.blocked_by?(@alice), "bob is blocked by alice"

    # blocked_with? is symmetric — the predicate hosts check in features.
    assert @alice.blocked_with?(@bob)
    assert @bob.blocked_with?(@alice)

    # Unrelated user is untouched.
    refute @alice.blocked_with?(@carol)
  end

  test "block! is idempotent — re-blocking the same pair adds no new edge" do
    @alice.block!(@bob)

    assert_no_difference -> { Moderate::Block.count } do
      result = @alice.block!(@bob)
      assert_kind_of Moderate::Block, result, "re-block returns the existing edge"
    end
  end

  test "a user cannot block themselves" do
    assert_no_difference -> { Moderate::Block.count } do
      block = Moderate::Block.block!(blocker: @alice, blocked: @alice)
      refute block.persisted?, "a self-block must not persist"
    end
    # blocked_with? against yourself is never true.
    refute @alice.blocked_with?(@alice)
  end

  test "unblock! removes the edge and the predicates flip back" do
    @alice.block!(@bob)
    assert @alice.blocks?(@bob)

    assert_difference -> { Moderate::Block.count }, -1 do
      assert @alice.unblock!(@bob), "unblock! returns true when an edge was removed"
    end

    refute @alice.blocks?(@bob)
    refute @bob.blocked_by?(@alice)
    refute @alice.blocked_with?(@bob)
  end

  test "unblock! is a safe no-op when there is no edge" do
    assert_no_difference -> { Moderate::Block.count } do
      refute @alice.unblock!(@bob), "unblock! returns false when nothing was removed"
    end
  end

  # --- Moderate.blocked_ids_for — the SSOT behind host enforcement ------------

  test "blocked_ids_for returns nothing for a user with no blocks" do
    assert_empty Moderate.blocked_ids_for(@alice).to_a
  end

  test "blocked_ids_for returns [] for a nil user (anonymous-safe)" do
    assert_equal [], Moderate.blocked_ids_for(nil)
  end

  test "blocked_ids_for includes people I BLOCKED (outgoing direction)" do
    @alice.block!(@bob)

    ids = Moderate.blocked_ids_for(@alice).map(&:id)
    assert_includes ids, @bob.id
    refute_includes ids, @carol.id
  end

  test "blocked_ids_for includes people who BLOCKED ME (incoming direction)" do
    # Bob blocks Alice. From Alice's perspective, Bob must STILL be hidden — the edge
    # is bidirectional in effect even though Alice never pressed the button. This is
    # the classic blocking bug the SSOT query exists to prevent.
    @bob.block!(@alice)

    ids = Moderate.blocked_ids_for(@alice).map(&:id)
    assert_includes ids, @bob.id, "a user who blocked me must be hidden from me too"
  end

  test "blocked_ids_for unions BOTH directions across multiple edges" do
    @alice.block!(@bob)   # outgoing
    @carol.block!(@alice) # incoming

    ids = Moderate.blocked_ids_for(@alice).map(&:id)
    assert_includes ids, @bob.id
    assert_includes ids, @carol.id
  end

  # --- The documented host enforcement pattern, exercised for real ------------

  test "the canonical where.not(user_id: blocked_ids_for) query hides blocked users' content" do
    # Each user authors a comment (a stand-in for any host content owned by a user).
    a_comment = Comment.create!(user: @alice, body: "alice says hi")
    b_comment = Comment.create!(user: @bob, body: "bob says hi")
    c_comment = Comment.create!(user: @carol, body: "carol says hi")

    # Bob blocked Alice (incoming, from Alice's view). The host runs the README query
    # to build Alice's feed; Bob's content must drop out, the rest must remain.
    @bob.block!(@alice)

    visible = Comment.where.not(user_id: Moderate.blocked_ids_for(@alice))

    assert_includes visible, a_comment, "my own content stays visible"
    assert_includes visible, c_comment, "an unrelated user's content stays visible"
    refute_includes visible, b_comment, "a blocked user's content is filtered out"
  end

  test "blocked_ids_for composes as a SQL subquery (relation, not a loaded array)" do
    @alice.block!(@bob)

    relation = Moderate.blocked_ids_for(@alice)
    # It must be a composable AR relation so the host's where.not runs entirely in SQL
    # (no N ids round-tripped to Ruby just to be sent back as a giant IN list).
    assert_kind_of ActiveRecord::Relation, relation
  end

  private

  def rewire_hooks(config = Moderate.config)
    config.audit = ->(event) { ModerateTestRecorder.audit(event) }
    config.notify = ->(event) { ModerateTestRecorder.notify(event) }
    config.on_block = ->(blocker:, blocked:) { ModerateTestRecorder.on_block(blocker: blocker, blocked: blocked) }
    config.ban_handler = ->(user:, by:, reason:) { ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason) }
    config
  end
end
