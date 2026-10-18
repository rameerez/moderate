# frozen_string_literal: true

require "test_helper"

# The immediate ClassifyJob and the after-upload guard running at the same moment on
# one attachment: the first claims the files under the content's row lock, the second
# finds the live claim and stops, so the adapter is called once; and while the adapter
# runs, no lock is held on the content's row. Real threads on real connections, so
# this test commits and cleans up after itself.
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

    attr_accessor :during_call

    def classify(_value)
      @calls.increment
      during_call&.call
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

    assert_equal 1, @adapter.calls.value, "the second job found the first one's live claim"
  end

  test "no lock is held on the content's row while the adapter runs" do
    updated = nil
    @adapter.during_call = lambda do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          with_short_lock_timeout(connection) do
            updated = Comment.where(id: @comment.id).update_all(body: "edited while classifying")
          end
        end
      end.join
    end

    Moderate::ClassifyJob.perform_now(Comment.find(@comment.id), "photo")

    assert_equal 1, updated, "another connection updated the row without waiting"
    assert_equal 1, @adapter.calls.value
  end

  private

  def with_short_lock_timeout(connection)
    if connection.adapter_name.downcase.include?("postgres")
      connection.execute("SET lock_timeout = '1s'")
    else
      connection.execute("SET SESSION innodb_lock_wait_timeout = 1")
    end
    yield
  ensure
    if connection.adapter_name.downcase.include?("postgres")
      connection.execute("SET lock_timeout = 0")
    else
      connection.execute("SET SESSION innodb_lock_wait_timeout = 50")
    end
  end
end
