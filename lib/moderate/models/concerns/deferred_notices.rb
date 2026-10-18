# frozen_string_literal: true

module Moderate
  # Notices that must not reach anyone before the change they announce is durable.
  #
  # A service changes a record inside a transaction, then queues what to send with
  # `record.after_commit_notice { … }`. The TRANSACTION owns the notice, exactly as it
  # owns a record's after_commit callbacks: the notice is wrapped in an Envelope and
  # enrolled in the current transaction (`connection.add_transaction_record`, the same
  # call Active Record makes for a saved record, on Rails 7.1, 7.2 and 8.x alike), and
  # the transaction finalizes it — sends it on commit, drops it on rollback or when an
  # exception ends the transaction. Nothing lives on a Ruby instance or on the thread,
  # so it doesn't matter which instance of a row was saved, whether the row was saved
  # at all, or which thread runs next.
  #
  # Notices follow Active Record's after_commit rules, exactly:
  #   - with no transaction open, the notice is sent at once;
  #   - a notice follows the CONNECTION ITS RECORD WAS SAVED ON (the pool, under
  #     multiple databases or shards): queue it in the same `connected_to` block as the
  #     save, or it follows the record's last save. Queued for a record never saved in
  #     this process, it follows the record class's current connection;
  #   - in nested transactions that join their parent, and in savepoints
  #     (`requires_new: true`) under a joinable parent, it moves up and is sent at the
  #     OUTERMOST commit; a rolled-back savepoint drops only its own notices;
  #   - under a parent that is not joinable (`transaction(joinable: false)`, and the
  #     wrapper Rails' transactional tests run each test in), it is sent when the
  #     savepoint is released — when after_commit runs too.
  module DeferredNotices
    extend ActiveSupport::Concern

    included do
      after_save :remember_moderate_connection_pool
      after_destroy :remember_moderate_connection_pool
    end

    # A queued notice, in the shape a transaction finalizes: Active Record calls
    # `before_committed!`, then `committed!` or `rolledback!` on every record enrolled
    # in it (and reads `trigger_transactional_callbacks?`, `destroyed?`,
    # `_new_record_before_last_commit` when choosing which instance runs callbacks).
    class Envelope
      attr_accessor :_new_record_before_last_commit

      def initialize(notice)
        @notice = notice
        @finalized = false
      end

      def trigger_transactional_callbacks? = true
      def has_transactional_callbacks? = true # rubocop:disable Naming/PredicatePrefix -- Active Record's name
      def destroyed? = false
      def before_committed!; end

      # Sent once, when the transaction that owns the envelope runs commit callbacks.
      # (Active Record also calls this with should_run_callbacks: false when it is only
      # cleaning up after an exception: nothing is sent then.)
      def committed!(should_run_callbacks: true)
        return if @finalized

        @finalized = true
        @notice.call if should_run_callbacks
      end

      def rolledback!(force_restore_state: false, should_run_callbacks: true) # rubocop:disable Lint/UnusedMethodArgument
        @finalized = true
      end
    end

    # Enroll `notice` in `connection`'s current transaction, or send it now when there
    # is no connection or it has no transaction open.
    def self.defer(connection, &notice)
      return notice.call unless connection&.current_transaction&.open?

      connection.add_transaction_record(Envelope.new(notice))
      nil
    end

    def after_commit_notice(&notice)
      DeferredNotices.defer(moderate_saved_connection, &notice)
      self
    end

    private

    # The connection the record was last saved (or destroyed) on, as THIS thread holds
    # it now: the pool remembered at save time, asked for the current thread's leased
    # connection (nil when the thread holds none: then no transaction can be open on
    # it). The pool, not the connection object: a connection returns to its pool and
    # can be leased by another thread, whose transaction a notice must never join.
    def moderate_saved_connection
      pool = @moderate_connection_pool || self.class.connection_pool
      pool.active_connection?
    end

    def remember_moderate_connection_pool
      @moderate_connection_pool = self.class.connection_pool
    end
  end
end
