# frozen_string_literal: true

require "test_helper"

# End-to-end content-filtering enforcement, driven entirely through the dummy host's
# Comment model (`moderates :body` / `moderates :image`) — no host-app specifics, just
# "a model with a moderated text column and a moderated attachment."
#
# This exercises the WHOLE filtering surface a host actually relies on:
#   - the three modes (:off / :block / :flag) behaving exactly as documented
#     (README "Content filtering: :off / :block / :flag"; docs/configuration.md
#     "default_filter_mode"),
#   - the load-bearing :flag invariant (the Flag is created AFTER COMMIT, never inside
#     the save transaction — README/docs: "`:flag` never lives in a validator"),
#   - the direct `Moderate.classify` entry point returning a coherent Moderate::Result.
#
# IMPORTANT (see test/dummy/config/initializers/moderate.rb): the suite's `setup`
# calls `Moderate.reset!`, which wipes the boot-time per-field policies back to "no
# policy" (== mode :off). So every test here RE-DECLARES the policy it needs inside
# its own `Moderate.configure` block — that's the canonical post-reset wiring the
# initializer documents, and it lets each test pin a single mode without bleeding into
# the next.
class ContentFilteringTest < ActiveSupport::TestCase
  # Text the built-in :wordlist adapter is known to flag (-> :harassment) vs. text it
  # lets through. We assert the wordlist's verdict directly first (below), so the rest
  # of the file can rely on these two strings as "the filter trips" / "the filter is
  # clean" without re-justifying the adapter each time.
  OBJECTIONABLE = "you are a bitch"
  CLEAN = "hello friendly neighbor"

  setup do
    @user = User.create!(name: "Author", email: "author@example.com")
    ModerateTestRecorder.clear
  end

  # --- Baseline: the adapter and the classify entry point ---------------------

  test "Moderate.classify routes through the default :wordlist adapter and returns a coherent Result" do
    # Re-point the recorder hooks (reset! cleared them); not strictly needed for
    # classify, but keeps this test's config shaped like the rest of the suite.
    rewire_hooks

    flagged = Moderate.classify(OBJECTIONABLE)
    refute flagged.allowed?, "objectionable text should not be allowed"
    assert flagged.flagged?, "flagged? is the inverse of allowed?"
    assert_includes flagged.categories, :harassment
    # The spine backfills `source` with the adapter NAME; the wordlist stamps its own
    # migration-constraint source ("text_filter"), which must survive that backfill.
    assert_equal "text_filter", flagged.source

    clean = Moderate.classify(CLEAN)
    assert clean.allowed?
    assert_empty clean.categories
  end

  # --- :off — no enforcement at all -------------------------------------------

  test ":off mode is a complete no-op — objectionable content saves and files no flag" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :off
    end

    comment = nil
    assert_no_difference -> { Moderate::Flag.count }, "an :off field must never file a flag" do
      comment = Comment.new(user: @user, body: OBJECTIONABLE)
      assert comment.save, "an :off field must never reject the save: #{comment.errors.full_messages.inspect}"
    end

    assert comment.persisted?
    assert_empty comment.errors[:body]
    assert_empty ModerateTestRecorder.notifications_named(:content_flagged)
  end

  test "a field with NO declared policy behaves like :off (filter_policy_for falls back to :off)" do
    # No `config.filter "Comment", ...` at all after reset!, so filter_policy_for
    # returns the synthesized :off policy. The save must go through untouched.
    Moderate.configure { |config| rewire_hooks(config) }

    comment = Comment.new(user: @user, body: OBJECTIONABLE)
    assert comment.save, "with no policy declared the field must not be enforced"
    assert_empty comment.errors[:body]
  end

  # --- :block — reject the save synchronously ---------------------------------

  test ":block mode rejects the save and adds an :objectionable_content error on the field" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :block
    end

    comment = Comment.new(user: @user, body: OBJECTIONABLE)

    assert_no_difference -> { Comment.count } do
      refute comment.save, ":block must reject an objectionable save"
    end
    refute comment.persisted?
    assert comment.errors.added?(:body, :objectionable_content),
      "expected an :objectionable_content error on :body, got #{comment.errors.details.inspect}"
    # A :block trip files NO Flag (it never committed) — the rejection IS the action.
    assert_equal 0, Moderate::Flag.count
  end

  test ":block mode lets clean content through with no error" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :block
    end

    comment = Comment.new(user: @user, body: CLEAN)
    assert comment.save, "clean content must save under :block: #{comment.errors.full_messages.inspect}"
    assert_empty comment.errors[:body]
  end

  test ":block mode skips a blank value (nothing to classify)" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :block
    end

    comment = Comment.new(user: @user, body: "")
    assert comment.save, "a blank moderated field must not be rejected"
  end

  # --- :flag — allow the save, file a Flag AFTER COMMIT ------------------------

  test ":flag mode allows the save AND files a pending Moderate::Flag after commit" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :flag
    end

    comment = nil
    assert_difference -> { Moderate::Flag.count }, 1, "a :flag trip must file exactly one Flag" do
      comment = Comment.new(user: @user, body: OBJECTIONABLE)
      assert comment.save, ":flag must NOT reject the save: #{comment.errors.full_messages.inspect}"
    end

    assert comment.persisted?, "the content itself must be saved under :flag"

    flag = Moderate::Flag.last
    assert_equal comment, flag.flaggable
    assert_equal "body", flag.field
    assert flag.pending?, "a fresh flag lands in the pending queue"
    assert_includes Array(flag.categories), "harassment"
    # `owner` is inferred from the flaggable's reported_owner (Comment#reported_owner => user).
    assert_equal @user, flag.owner
    # `mode` records what the filter WOULD do; `source` is the adapter's wire name.
    assert_equal "flag", flag.mode
    assert_equal "text_filter", flag.source
    # The flagged content surfaces in the same queue admins and ML consumers read.
    assert_includes Moderate::Flag.pending, flag
  end

  test ":flag mode files NO flag for clean content" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :flag
    end

    assert_no_difference -> { Moderate::Flag.count } do
      comment = Comment.new(user: @user, body: CLEAN)
      assert comment.save
    end
  end

  test ":flag mode re-saving an UNCHANGED field does not re-flag it (no queue spam)" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :flag
    end

    comment = Comment.create!(user: @user, body: OBJECTIONABLE)
    assert_equal 1, Moderate::Flag.count, "the initial objectionable save flags once"

    # Touch an UNRELATED attribute so the record saves again but :body is unchanged.
    assert_no_difference -> { Moderate::Flag.count }, "an untouched moderated field must not re-flag on re-save" do
      comment.update!(updated_at: Time.current + 1)
    end
  end

  test ":flag mode fires the content_flagged notification after the flag commits" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :flag
    end

    Comment.create!(user: @user, body: OBJECTIONABLE)

    flagged_events = ModerateTestRecorder.notifications_named(:content_flagged)
    assert_equal 1, flagged_events.size, "exactly one content_flagged event should fire"
    # content_flagged is an admin/system signal — no user recipient by design.
    assert_empty Array(flagged_events.first.recipients)
  end

  # --- Mode independence: changing the policy changes behavior, same model -----

  test "the SAME model+field switches enforcement purely by config mode (no model change)" do
    # :block first.
    Moderate.configure do |config|
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :block
    end
    rejected = Comment.new(user: @user, body: OBJECTIONABLE)
    refute rejected.save, "policy mode :block should reject"

    # Flip to :flag — the very same model/field now allows + flags instead.
    Moderate.reset!
    Moderate.configure do |config|
      config.user_class = "User"
      rewire_hooks(config)
      config.filter "Comment", :body, with: :wordlist, mode: :flag
    end
    accepted = nil
    assert_difference -> { Moderate::Flag.count }, 1 do
      accepted = Comment.new(user: @user, body: OBJECTIONABLE)
      assert accepted.save, "policy mode :flag should allow + flag"
    end
    assert accepted.persisted?
  end

  # --- Image (attachment) field: async adapter, :flag-only --------------------

  test ":flag mode with an ASYNC adapter never classifies inline — Moderate::ClassifyJob files the flag" do
    Moderate.configure do |config|
      rewire_hooks(config)
      # Image moderation is bring-your-own — the gem ships only the offline text
      # :wordlist. The dummy host registers a tiny async image adapter under :image
      # (test/dummy/app/adapters/dummy_image_adapter.rb); it's async, so it's only
      # valid in :flag mode (validate! would reject :block + an async adapter). This
      # mirrors the dummy Comment#image policy.
      config.register_adapter :image, DummyImageAdapter.new
      config.filter "Comment", :image, with: :image, mode: :flag
    end

    comment = Comment.new(user: @user, body: CLEAN)
    comment.image.attach(
      io: StringIO.new("not really an image, the adapter ignores the bytes"),
      filename: "avatar.png",
      content_type: "image/png"
    )

    # The whole point of async routing: the save's after_commit must NOT call the
    # (network-bound, in real life) adapter inline — it enqueues the job instead.
    assert_no_difference -> { Moderate::Flag.count }, "an async adapter must not classify inline" do
      assert_enqueued_with(job: Moderate::ClassifyJob) do
        assert comment.save, "an image upload under :flag must not be rejected"
      end
    end

    assert_difference -> { Moderate::Flag.count }, 1, "ClassifyJob files the flag for the uploaded image" do
      perform_enqueued_jobs(only: Moderate::ClassifyJob)
    end

    flag = Moderate::Flag.where(field: "image").last
    assert_not_nil flag, "an image flag should be filed for the :image field"
    assert_equal "image", flag.source
    assert_equal comment, flag.flaggable
  end

  test "a NATIVE attachment field (no seam overrides) is tracked, enqueued, and re-save-safe" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.register_adapter :image, DummyImageAdapter.new
      # Comment#photo has NO moderation_field_* overrides (they're scoped to
      # :image) — this policy rides entirely on the concern's built-in
      # before_save attachment snapshot.
      config.filter "Comment", :photo, with: :image, mode: :flag
    end

    comment = Comment.new(user: @user, body: CLEAN)
    comment.photo.attach(
      io: StringIO.new("bytes"),
      filename: "photo.png",
      content_type: "image/png"
    )

    assert_enqueued_with(job: Moderate::ClassifyJob) { assert comment.save }
    assert_difference -> { Moderate::Flag.count }, 1 do
      perform_enqueued_jobs(only: Moderate::ClassifyJob)
    end
    assert_equal comment, Moderate::Flag.where(field: "photo").last.flaggable

    # Re-saving the record WITHOUT touching the attachment must not re-enqueue —
    # the snapshot is one-shot, so an untouched photo can't spam the queue.
    assert_no_enqueued_jobs(only: Moderate::ClassifyJob) do
      comment.update!(body: "#{CLEAN} edited")
    end
  end

  test "ClassifyJob is a no-op when the attachment vanished between enqueue and run" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.register_adapter :image, DummyImageAdapter.new
      config.filter "Comment", :photo, with: :image, mode: :flag
    end

    comment = Comment.new(user: @user, body: CLEAN)
    comment.photo.attach(io: StringIO.new("bytes"), filename: "photo.png", content_type: "image/png")
    comment.save!

    # Purge before the job runs (user deleted it, moderation raced) — the job
    # re-reads the CURRENT value, sees an unattached proxy, and files nothing.
    comment.photo.purge

    assert_no_difference -> { Moderate::Flag.count } do
      perform_enqueued_jobs(only: Moderate::ClassifyJob)
    end
  end

  test "a registered adapter can be a string class name and records the adapter name as the flag source" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.register_adapter :string_image, "DummyImageAdapter"
      config.filter "Comment", :image, with: :string_image, mode: :flag
    end

    comment = Comment.new(user: @user, body: CLEAN)
    comment.image.attach(
      io: StringIO.new("not really an image"),
      filename: "avatar.png",
      content_type: "image/png"
    )

    assert comment.save
    assert_difference -> { Moderate::Flag.count }, 1 do
      perform_enqueued_jobs(only: Moderate::ClassifyJob)
    end

    assert_equal "string_image", Moderate::Flag.where(field: "image").last.source
  end

  test "adapter_async? reports the routing decision (wordlist inline, remote adapters via job)" do
    Moderate.configure do |config|
      rewire_hooks(config)
      config.register_adapter :image, DummyImageAdapter.new
    end

    refute Moderate.config.adapter_async?(:wordlist), "the built-in wordlist classifies inline"
    assert Moderate.config.adapter_async?(:image), "an adapter answering synchronous? == false routes through ClassifyJob"
    refute Moderate.config.adapter_async?(:nonexistent), "unknown adapters default to inline (classify raises its own error)"
  end

  private

  # Re-point the four host hooks at the in-memory recorder after `reset!` wiped them.
  # Accepts an optional live config (when called inside a configure block) or grabs the
  # singleton (when called standalone). Mirrors test/dummy/config/initializers/moderate.rb.
  def rewire_hooks(config = Moderate.config)
    config.audit = ->(event) { ModerateTestRecorder.audit(event) }
    config.notify = ->(event) { ModerateTestRecorder.notify(event) }
    config.on_block = ->(blocker:, blocked:, at:) { ModerateTestRecorder.on_block(blocker: blocker, blocked: blocked, at: at) }
    config.ban_handler = ->(user:, by:, reason:) { ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason) }
    config
  end
end
