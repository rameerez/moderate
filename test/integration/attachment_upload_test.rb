# frozen_string_literal: true

require "test_helper"

# An attached file is classified once Active Storage has uploaded it, and never
# before.
#
# Active Storage uploads a newly attached file in its own after_commit callback
# (`has_one_attached` / `has_many_attached` register it). On Rails 7.1+ commit
# callbacks run in the order they were defined, so a model that calls `moderates`
# (which registers the filter's after_commit) ABOVE `has_one_attached` used to run
# the filter first: a synchronous adapter classified a blob whose file wasn't on
# the service yet, and an async adapter's ClassifyJob was enqueued while the upload
# was still in flight (CarHey's 2026-07-10 incident). The dummy's Comment has that
# order: `moderates :body` comes before `has_one_attached :photo`.
class AttachmentUploadTest < ActiveSupport::TestCase
  # A synchronous image adapter that records, for every call, whether the file it
  # was handed exists on the storage service at that moment.
  class RecordingAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def synchronous? = true

    def classify(value)
      blobs = value.respond_to?(:blobs) ? value.blobs.to_a : [value.blob]
      @calls << blobs.all? { |blob| blob.service.exist?(blob.key) }
      label = Moderate::Label.new(category: :sexual, subcategory: nil, score: 1.0, flagged: true, input: :image)
      Moderate::Result.new(allowed: false, labels: [label], source: "image_filter")
    end
  end

  setup do
    @user = User.create!(name: "Author", email: "author@example.com")
    @adapter = RecordingAdapter.new
    ModerateTestRecorder.clear
  end

  def configure(model: "Comment", field: :photo, adapter: @adapter)
    Moderate.configure do |config|
      config.audit = ->(event) { ModerateTestRecorder.audit(event) }
      config.notify = ->(event) { ModerateTestRecorder.notify(event) }
      config.register_adapter :recording, adapter
      config.register_adapter :image, DummyImageAdapter.new
      config.filter model, field, with: (adapter.synchronous? ? :recording : :image), mode: :flag
    end
  end

  def attach_photo(record)
    record.photo.attach(io: StringIO.new("bytes"), filename: "photo.png", content_type: "image/png")
  end

  test "a synchronous adapter classifies an attachment declared below `moderates` only after its upload" do
    configure

    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)

    assert_difference -> { Moderate::Flag.where(field: "photo").count }, 1 do
      comment.save!
    end
    assert_equal [true], @adapter.calls, "classified once, with the file already on the service"
  end

  test "replacing the attachment on a saved record is classified after the new upload" do
    configure
    comment = Comment.create!(user: @user, body: "hello")

    attach_photo(comment)

    assert_equal [true], @adapter.calls
    assert_equal 1, Moderate::Flag.where(flaggable: comment, field: "photo").count
  end

  test "an async adapter: a guard job before the upload, the classifying job after it, one flag" do
    configure(adapter: DummyImageAdapter.new)
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Aenqueue(_at)?\.active_job\z/) do |name, *, payload|
      job = payload[:job]
      next unless job.is_a?(Moderate::ClassifyJob)

      blob = job.arguments.first.photo.blob
      seen << [name.start_with?("enqueue_at") ? :scheduled : :now, blob.service.exist?(blob.key)]
    end

    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)
    comment.save!

    assert_equal [[:scheduled, false], [:now, true]], seen,
      "the guard is queued (for later) before the upload; the immediate job after it"
    assert_difference -> { Moderate::Flag.where(field: "photo").count }, 1, "the second job finds the first one's mark" do
      drain_classify_jobs
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "the guard job finds an inline classification done and doesn't classify again" do
    configure
    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)
    comment.save!
    assert_equal [true], @adapter.calls

    drain_classify_jobs

    assert_equal [true], @adapter.calls
    assert_equal 1, Moderate::Flag.where(field: "photo").count
  end

  test "a direct upload still in flight is classified by the job once its file arrives, never before" do
    configure
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "direct.png", byte_size: 5, checksum: OpenSSL::Digest::MD5.base64digest("bytes"), content_type: "image/png"
    )
    # Identified already (an API client that created the blob, a content type it
    # declared), so Active Storage doesn't read the file at attach time.
    blob.update!(identified: true)
    comment = Comment.new(user: @user, body: "hello")
    comment.photo.attach(blob.signed_id) # the client hasn't PUT the file yet

    comment.save!
    perform_classify_jobs_once

    assert_empty @adapter.calls, "a synchronous adapter isn't handed a file that isn't there"

    blob.service.upload(blob.key, StringIO.new("bytes"))
    drain_classify_jobs

    assert_equal [true], @adapter.calls
    assert_equal 1, Moderate::Flag.where(flaggable: comment, field: "photo").count
  end

  test "an upload that raises still ends in a classification_skipped audit, never in silence" do
    configure
    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)

    ActiveStorage::Blob.any_instance.stubs(:upload_without_unfurling).raises(Errno::ECONNRESET)
    assert_raises(Errno::ECONNRESET) { comment.save! }
    ActiveStorage::Blob.any_instance.unstub(:upload_without_unfurling)

    drain_classify_jobs

    assert_empty @adapter.calls
    skipped = ModerateTestRecorder.audits_named(:classification_skipped)
    assert_equal(["attachment_not_uploaded"], skipped.map { |event| event.payload[:reason] })
  end

  test "a job for files the field no longer holds stops: the newer change has its own" do
    configure(adapter: DummyImageAdapter.new)
    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)
    comment.save!
    old_jobs = enqueued_jobs.dup
    clear_enqueued_jobs
    attach_photo(comment) # replaced before the first jobs ran
    clear_enqueued_jobs

    old_jobs.each { |job| ActiveJob::Base.execute(job) }

    assert_equal 0, Moderate::Flag.where(field: "photo").count
  end

  test "an attachment declared above `moderates` is classified once, right away" do
    configure(model: "PhotoPost")

    post = PhotoPost.new(user: @user, body: "hello")
    attach_photo(post)

    assert_difference -> { Moderate::Flag.where(field: "photo").count }, 1 do
      post.save!
    end
    assert_equal [true], @adapter.calls
  end

  test "has_many_attached files declared below `moderates` are classified after they all upload" do
    configure(model: "PhotoPost", field: :photos)

    post = PhotoPost.new(user: @user, body: "hello")
    post.photos.attach(
      { io: StringIO.new("one"), filename: "one.png", content_type: "image/png" },
      { io: StringIO.new("two"), filename: "two.png", content_type: "image/png" }
    )

    assert_difference -> { Moderate::Flag.where(field: "photos").count }, 1 do
      post.save!
    end
    assert_equal [true], @adapter.calls
  end

  test "a save that doesn't touch the attachment doesn't classify it again" do
    configure
    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)
    comment.save!

    comment.update!(body: "hello again")

    assert_equal [true], @adapter.calls
  end

  # --- ClassifyJob: a blob that isn't on the service yet ----------------------

  test "ClassifyJob waits for a blob that isn't on the service yet, then classifies it" do
    configure(adapter: DummyImageAdapter.new)
    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)
    comment.save!
    clear_enqueued_jobs

    blob = comment.photo.blob
    bytes = blob.download
    blob.service.delete(blob.key) # a direct upload still in flight, a slow replica

    assert_no_difference -> { Moderate::Flag.count } do
      assert_enqueued_with(job: Moderate::ClassifyJob, args: [comment, "photo", { adapter: nil, upload_attempt: 2, blob_ids: nil }]) do
        Moderate::ClassifyJob.perform_now(comment, "photo")
      end
    end

    blob.service.upload(blob.key, StringIO.new(bytes))
    clear_enqueued_jobs

    assert_difference -> { Moderate::Flag.where(field: "photo").count }, 1 do
      Moderate::ClassifyJob.perform_now(comment, "photo", upload_attempt: 2)
    end
  end

  test "ClassifyJob gives up on a blob that never reaches the service, and audits it" do
    configure(adapter: DummyImageAdapter.new)
    comment = Comment.new(user: @user, body: "hello")
    attach_photo(comment)
    comment.save!
    clear_enqueued_jobs
    comment.photo.blob.service.delete(comment.photo.blob.key)

    assert_no_enqueued_jobs(only: Moderate::ClassifyJob) do
      Moderate::ClassifyJob.perform_now(comment, "photo", upload_attempt: Moderate::ClassifyJob::UPLOAD_ATTEMPTS)
    end

    assert_equal 0, Moderate::Flag.count
    skipped = ModerateTestRecorder.audits_named(:classification_skipped)
    assert_equal 1, skipped.size
    assert_equal "photo", skipped.first.payload[:field]
    assert_equal "attachment_not_uploaded", skipped.first.payload[:reason]
  end

  private

  # Run every ClassifyJob, including the ones they re-enqueue, scheduled or not.
  def drain_classify_jobs
    20.times do
      jobs = enqueued_jobs.select { |job| job["job_class"] == "Moderate::ClassifyJob" }
      return if jobs.empty?

      clear_enqueued_jobs
      jobs.each { |job| ActiveJob::Base.execute(job) }
    end
    flunk "ClassifyJob kept re-enqueuing itself"
  end

  def perform_classify_jobs_once
    jobs = enqueued_jobs.select { |job| job["job_class"] == "Moderate::ClassifyJob" }
    clear_enqueued_jobs
    jobs.each { |job| ActiveJob::Base.execute(job) }
  end
end
