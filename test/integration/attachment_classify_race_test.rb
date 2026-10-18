# frozen_string_literal: true

require "test_helper"

# The immediate ClassifyJob and the after-upload guard running at the same moment on
# one attachment: both take the content record's row lock around check + classify +
# mark (Moderate::Attachments), so the second finds the first one's mark and the
# adapter is called once. Real threads on real connections, so this test commits and
# cleans up after itself.
#
# PostgreSQL and MySQL only: SQLite has no row locks (SELECT ... FOR UPDATE is a
# no-op there), so there is nothing for this test to prove on it.
class AttachmentClassifyRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # An async adapter (so saving only enqueues) that is slow and counts its calls.
  class SlowAdapter
    attr_reader :calls

    def initialize
      @calls = Concurrent::AtomicFixnum.new
    end

    def synchronous? = false

    def classify(_value)
      @calls.increment
      sleep 0.3
      Moderate::Result.allowed(source: "image_filter")
    end
  end

  setup do
    skip "SQLite has no row locks" if ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")

    @adapter = SlowAdapter.new
    Moderate.configure do |config|
      config.register_adapter :slow, @adapter
      config.filter "Comment", :photo, with: :slow, mode: :flag
    end
    @author = User.create!(name: "Author #{SecureRandom.hex(3)}")
    @comment = Comment.new(user: @author, body: "hello")
    @comment.photo.attach(io: StringIO.new("bytes"), filename: "photo.png", content_type: "image/png")
    @comment.save!
    clear_enqueued_jobs
  end

  teardown do
    next unless @comment

    Moderate::Flag.where(flaggable: @comment).delete_all
    @comment.photo.purge
    @comment.destroy
    @author.destroy
  end

  test "two jobs for one set of files at once: one adapter call" do
    gate = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          Moderate::ClassifyJob.perform_now(Comment.find(@comment.id), "photo")
        end
      end
    end
    2.times { gate << :go }
    threads.each(&:join)

    assert_equal 1, @adapter.calls.value, "the second job waited for the lock, then found the mark"
  end
end
