# frozen_string_literal: true

require "test_helper"

module Moderate
  # Tests for Moderate::Flag — the system/auto-filter review signal.
  #
  # Ported from test/models/moderation/flag_test.rb and realigned to the GEM API:
  # the `content_flagged` Event's SUBJECT is the Flag itself (the reference put the
  # flag under `payload[:flag]`), and the `flag!` entrypoint takes the full keyword
  # set the migration's columns require (categories/scores/context/excerpt/mode).
  class FlagTest < ActiveSupport::TestCase
    setup do
      @user = create_user
    end

    test "flag! creates a pending review signal for a polymorphic target" do
      flag = Moderate::Flag.flag!(
        flaggable: @user,
        field: "name",
        owner: @user,
        source: "image_filter",
        mode: "flag",
        excerpt: "name excerpt",
        categories: ["sexual"],
        scores: { "sexual" => 1.0 },
        context: { "human_review_required" => true }
      )

      assert_predicate flag, :pending?
      assert_equal @user, flag.flaggable
      assert_equal @user, flag.owner
      # flag! coerces categories→Array and scores/context→Hash, persisting them as JSON.
      assert_equal ["sexual"], flag.categories
      assert_equal({ "sexual" => 1.0 }, flag.scores)
      assert_equal({ "human_review_required" => true }, flag.context)
    end

    test "flag! notifies :content_flagged with the flag as the event subject" do
      notifications = []
      Moderate.config.notify = ->(event) { notifications << event; true }

      flag = Moderate::Flag.flag!(
        flaggable: @user,
        field: "name",
        owner: @user,
        source: "image_filter",
        mode: "flag",
        excerpt: "name excerpt",
        categories: ["sexual"],
        scores: { "sexual" => 1.0 },
        context: {}
      )

      assert_equal [:content_flagged], notifications.map(&:name)
      assert_equal flag, notifications.first.subject
      # content_flagged is an admin/system signal — it has NO user recipient.
      assert_empty notifications.first.recipients
      assert_equal "image_filter", notifications.first.payload[:source]
    end

    test "pending scope returns only pending flags" do
      pending = Moderate::Flag.flag!(
        flaggable: @user, field: "name", owner: @user, source: "manual", mode: "flag",
        excerpt: "x", categories: [], scores: {}, context: {}
      )
      closed = Moderate::Flag.flag!(
        flaggable: @user, field: "name", owner: @user, source: "manual", mode: "flag",
        excerpt: "x", categories: [], scores: {}, context: {}
      )
      # Closing requires a note (validates resolution_note when closed?).
      closed.update!(status: "actioned", resolution_note: "handled")

      pending_ids = Moderate::Flag.pending.pluck(:id)
      assert_includes pending_ids, pending.id
      refute_includes pending_ids, closed.id
    end

    test "closing a flag without a resolution note is rejected" do
      flag = Moderate::Flag.flag!(
        flaggable: @user, field: "name", owner: @user, source: "manual", mode: "flag",
        excerpt: "x", categories: [], scores: {}, context: {}
      )

      flag.status = "dismissed"
      refute flag.valid?
      assert flag.errors[:resolution_note].any?
    end

    test "source/mode/status are constrained to the allowed vocabularies (in the model)" do
      # These vocabularies are enforced by ActiveModel inclusion validations, not DB
      # check constraints, so each invalid value surfaces a friendly model error.
      bad_source = Moderate::Flag.new(flaggable: @user, field: "name", source: "bogus", mode: "flag", status: "pending")
      refute bad_source.valid?
      assert bad_source.errors[:source].any?

      bad_mode = Moderate::Flag.new(flaggable: @user, field: "name", source: "manual", mode: "annihilate", status: "pending")
      refute bad_mode.valid?
      assert bad_mode.errors[:mode].any?

      bad_status = Moderate::Flag.new(flaggable: @user, field: "name", source: "manual", mode: "flag", status: "frozen")
      refute bad_status.valid?
      assert bad_status.errors[:status].any?
    end

    test "flaggable_label asks the flaggable, falling back to Type id" do
      # Comment implements moderation_label ("Comment ##{id}").
      comment = Comment.create!(user: @user, body: "a perfectly fine comment")
      flag = Moderate::Flag.flag!(
        flaggable: comment, field: "body", owner: @user, source: "text_filter", mode: "flag",
        excerpt: "x", categories: ["harassment"], scores: {}, context: {}
      )

      assert_equal "Comment ##{comment.id}", flag.flaggable_label
    end

    test "the :flag-mode filter files a Flag after_commit through the configured policy" do
      # Image moderation is bring-your-own (the gem ships only the offline text
      # :wordlist). The dummy host registers a tiny async image adapter under :image
      # (test/dummy/app/adapters/dummy_image_adapter.rb) that flags every uploaded
      # image for human review; we re-register + re-establish that policy here (setup's
      # Moderate.reset! wiped both the adapter and the policy). Attaching one image
      # should produce exactly one pending Flag on (comment, "image") after commit.
      Moderate.config.register_adapter :image, DummyImageAdapter.new
      Moderate.config.filter "Comment", :image, with: :image, mode: :flag
      comment = Comment.create!(user: @user, body: "clean body")

      assert_difference -> { Moderate::Flag.pending.where(flaggable: comment, field: "image").count }, 1 do
        comment.image.attach(io: StringIO.new("fake image bytes"), filename: "pic.png", content_type: "image/png")
      end

      flag = Moderate::Flag.pending.where(flaggable: comment, field: "image").last
      assert_equal "image", flag.source
      assert_equal comment.user, flag.owner # owner inferred from reported_owner
    end

    private

    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end
  end
end
