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
        flaggable: @user, field: "display_name", owner: @user, source: "manual", mode: "flag",
        excerpt: "x", categories: [], scores: {}, context: {}
      )
      # Closing requires a note (validates resolution_note when closed?).
      closed.update!(status: "actioned", resolution_note: "handled")

      pending_ids = Moderate::Flag.pending.pluck(:id)
      assert_includes pending_ids, pending.id
      refute_includes pending_ids, closed.id
    end

    # --- One pending flag per content + field (the unique pending_key) -------------

    test "the database refuses a second pending flag on the same content and field" do
      first = pending_flag_on(@user, "name")

      assert_equal "User/#{@user.id}/name", first.pending_key
      assert_raises(ActiveRecord::RecordNotUnique) do
        Moderate::Flag.transaction(requires_new: true) do
          Moderate::Flag.create!(flaggable: @user, field: "name", source: "manual", mode: "flag")
        end
      end
      assert_equal 1, Moderate::Flag.where(flaggable: @user, field: "name").count
    end

    test "closing a flag frees its content and field for a new pending one" do
      first = pending_flag_on(@user, "name")
      first.dismiss!(note: "Fine.")

      assert_nil first.reload.pending_key
      second = pending_flag_on(@user, "name")
      assert_predicate second, :previously_new_record?
      assert_not_equal first, second
    end

    test "a flag on another field, or other content, is independent" do
      first = pending_flag_on(@user, "name")
      other_field = pending_flag_on(@user, "display_name")
      other_content = pending_flag_on(create_user, "name")

      assert_equal 3, [first, other_field, other_content].map(&:id).uniq.size
    end

    # Two record classes on one table whose names differ only by case, so their keys
    # do too: MySQL's default collation would make them one key.
    class CaseKeyRecord < ActiveRecord::Base
      self.table_name = "users"
    end

    class CASEKEYRECORD < ActiveRecord::Base
      self.table_name = "users"
    end

    test "keys compare as bytes: content types that differ only by case get a pending flag each" do
      lower = pending_flag_on(CaseKeyRecord.find(@user.id), "name")
      upper = pending_flag_on(CASEKEYRECORD.find(@user.id), "name")

      assert_predicate upper, :previously_new_record?, "not joined to the other type's flag"
      assert_not_equal lower, upper
      assert_equal lower, pending_flag_on(CaseKeyRecord.find(@user.id), "name")
    end

    test "the unique index compares bytes: 'Post' and 'POST' keys coexist, a true duplicate is refused" do
      row = lambda do |type|
        { flaggable_type: type, flaggable_id: @user.id, field: "name", source: "manual", mode: "flag",
          status: "pending", categories: [], scores: {}, context: {}, pending_key: "#{type}/#{@user.id}/name",
          created_at: Time.current, updated_at: Time.current }
      end

      Moderate::Flag.insert_all!([row.call("Post")])
      assert_nothing_raised { Moderate::Flag.insert_all!([row.call("POST")]) }
      assert_raises(ActiveRecord::RecordNotUnique) do
        Moderate::Flag.transaction(requires_new: true) { Moderate::Flag.insert_all!([row.call("Post")]) }
      end
    end

    test "reopening a closed flag takes the key back, and refuses if another flag is pending there" do
      first = pending_flag_on(@user, "name")
      first.dismiss!(note: "Fine.")
      first.update!(status: "pending", resolution_note: nil)
      assert_equal "User/#{@user.id}/name", first.reload.pending_key

      first.dismiss!(note: "Fine again.")
      pending_flag_on(@user, "name")
      assert_raises(ActiveRecord::RecordNotUnique) do
        Moderate::Flag.transaction(requires_new: true) { first.update!(status: "pending", resolution_note: nil) }
      end
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

    test "a flag can be closed after its source adapter is no longer registered" do
      Moderate.config.register_adapter :temporary, DummyImageAdapter.new
      flag = Moderate::Flag.flag!(
        flaggable: @user, field: "name", owner: @user, source: "temporary", mode: "flag",
        excerpt: "x", categories: [], scores: {}, context: {}
      )

      Moderate.reset!
      Moderate.configure { |config| config.user_class = "User" }

      assert_nothing_raised do
        flag.update!(status: "dismissed", resolution_note: "Handled after adapter cleanup.")
      end
      assert_equal "dismissed", flag.reload.status
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
      # Moderate.reset! wiped both the adapter and the policy). The adapter is ASYNC,
      # so the after_commit enqueues Moderate::ClassifyJob rather than classifying
      # inline; performing the job produces exactly one pending Flag on
      # (comment, "image").
      Moderate.config.register_adapter :image, DummyImageAdapter.new
      Moderate.config.filter "Comment", :image, with: :image, mode: :flag
      comment = Comment.create!(user: @user, body: "clean body")

      assert_difference -> { Moderate::Flag.pending.where(flaggable: comment, field: "image").count }, 1 do
        comment.image.attach(io: StringIO.new("fake image bytes"), filename: "pic.png", content_type: "image/png")
        perform_enqueued_jobs(only: Moderate::ClassifyJob)
      end

      flag = Moderate::Flag.pending.where(flaggable: comment, field: "image").last
      assert_equal "image", flag.source
      assert_equal comment.user, flag.owner # owner inferred from reported_owner
    end

    test "action! closes the flag with reviewer, note and timestamp" do
      flag = build_pending_flag
      moderator = create_user

      flag.action!(by: moderator, note: "Photo removed, user warned.")

      assert_predicate flag.reload, :closed?
      assert_equal "actioned", flag.status
      assert_equal moderator, flag.reviewed_by
      assert_equal "Photo removed, user warned.", flag.resolution_note
      assert_not_nil flag.reviewed_at
    end

    test "dismiss! closes with no reviewer by default — automated closes must not fake a human" do
      flag = build_pending_flag

      flag.dismiss!(note: "Superseded: the flagged photo was replaced by the user.")

      assert_equal "dismissed", flag.reload.status
      assert_nil flag.reviewed_by
      assert_predicate flag.resolution_note, :present?
      # `flagged?` (pending-only) releases the record the moment the flag closes.
      assert_not @user.flagged?("name")
    end

    test "closing without a note is refused — every closed flag must explain itself" do
      flag = build_pending_flag

      assert_raises(ActiveRecord::RecordInvalid) { flag.dismiss!(note: nil) }
      assert_predicate flag.reload, :pending?
    end

    # --- Manual review flags ----------------------------------------------------

    test "flag_for_review! files a manual flag owned by the content's person" do
      admin = create_user
      comment = Comment.create!(user: @user, body: "see you on the ladder")
      ModerateTestRecorder.clear
      Moderate.configure { |config| config.audit = ->(event) { ModerateTestRecorder.audit(event) } }

      flag = Moderate::Flag.flag_for_review!(comment, field: :body, by: admin, note: "  Odd tone  ")

      assert_predicate flag, :previously_new_record?
      assert_predicate flag, :pending?
      assert_equal "manual", flag.source
      assert_equal "body", flag.field
      assert_equal @user, flag.owner
      assert_equal "see you on the ladder", flag.excerpt
      assert_equal [], flag.categories
      assert_equal({ "flagged_by_id" => admin.id, "note" => "Odd tone" }, flag.context)
      assert_predicate comment, :flagged?

      filed = ModerateTestRecorder.audits_named(:flag_filed).sole
      assert_equal admin, filed.actor
      assert_equal flag, filed.subject
    end

    test "flag_for_review! returns the flag already waiting instead of a second one" do
      comment = Comment.create!(user: @user, body: "hello")
      first = Moderate::Flag.flag_for_review!(comment, field: "body", by: create_user)

      again = assert_no_difference(-> { Moderate::Flag.count }) do
        Moderate::Flag.flag_for_review!(comment, field: :body, by: create_user)
      end

      assert_equal first, again
      assert_not_predicate again, :previously_new_record?
    end

    test "flag_for_review! files again once the earlier flag was decided" do
      comment = Comment.create!(user: @user, body: "hello")
      Moderate::Flag.flag_for_review!(comment, field: :body, by: nil).dismiss!(note: "Fine.")

      assert_predicate Moderate::Flag.flag_for_review!(comment, field: :body, by: nil), :previously_new_record?
    end

    test "flag_for_review! locks the row without touching the caller's object" do
      comment = Comment.create!(user: @user, body: "hello")
      comment.body = "an unsaved edit"

      Moderate::Flag.flag_for_review!(comment, field: :body, by: nil)

      assert_equal "an unsaved edit", comment.body, "not reloaded, and not refused for its unsaved change"
    end

    test "flag_for_review! needs a field and a saved record" do
      assert_raises(ArgumentError) { Moderate::Flag.flag_for_review!(@user, field: "", by: nil) }
      assert_raises(ArgumentError) { Moderate::Flag.flag_for_review!(Comment.new(user: @user), field: :body, by: nil) }
    end

    private

    def pending_flag_on(flaggable, field)
      Moderate::Flag.flag!(
        flaggable: flaggable, field: field, owner: nil, source: "manual", mode: "flag",
        excerpt: nil, categories: [], scores: {}, context: {}
      )
    end

    def build_pending_flag
      Moderate::Flag.flag!(
        flaggable: @user, field: "name", owner: @user, source: "image_filter",
        mode: "flag", excerpt: "", categories: [ "quality" ], scores: {}, context: {}
      )
    end

    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end
  end
end
