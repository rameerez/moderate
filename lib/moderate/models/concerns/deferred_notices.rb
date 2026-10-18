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
  #   - the notice joins the transaction of the connection it is queued ON. Queue it
  #     inside the transaction that saved the record, on that transaction's connection:
  #     `after_commit_notice(on: connection)`, where `on:` defaults to the record
  #     class's connection at call time. The gem's services capture their model's
  #     connection at the top of the transaction, before any save, and pass it to every
  #     notice they queue, so a host callback that switches databases or shards
  #     mid-save can't move them. A host that calls after_commit_notice itself passes
  #     `on:` when it uses `connected_to`;
  #   - in nested transactions that join their parent, and in savepoints
  #     (`requires_new: true`) under a joinable parent, it moves up and is sent at the
  #     OUTERMOST commit; a rolled-back savepoint drops only its own notices;
  #   - under a parent that is not joinable (`transaction(joinable: false)`, and the
  #     wrapper Rails' transactional tests run each test in), it is sent when the
  #     savepoint is released — when after_commit runs too.
  module DeferredNotices
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

    # The connection a service captures at the top of its transaction, before any save.
    def self.connection_for(model)
      model.respond_to?(:lease_connection) ? model.lease_connection : model.connection
    end

    def after_commit_notice(on: DeferredNotices.connection_for(self.class), &notice)
      DeferredNotices.defer(on, &notice)
      self
    end
  end
end
