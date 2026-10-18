# frozen_string_literal: true

module Moderate
  # Notices that must not reach anyone before the change they announce is durable.
  #
  # A service saves a record inside a transaction, then queues what to send with
  # `record.after_commit_notice { … }`. The notice is sent when the OUTERMOST
  # transaction commits — the gem's, or a host's around it — and dropped if it rolls
  # back, so a host that decides, reports or blocks inside a transaction of its own and
  # then rolls it back tells nobody. Plain Active Record transactional callbacks, so
  # Rails 7.1, 7.2 and 8.x behave the same.
  #
  # The queue is NOT kept on the Ruby instance: Active Record runs a row's commit
  # callbacks on ONE of the instances saved in the transaction (the first saved, or
  # the freshest, depending on `run_commit_callbacks_on_first_saved_instances_in_transaction`),
  # and host code may save another instance of the same row after ours. Entries live
  # in an execution-local registry keyed by the row (model + id), each tagged with the
  # state of the transaction it was queued in; `after_commit` on ANY instance of that
  # row sends the row's committed entries, and a rollback drops whatever it rolled back.
  #
  # Queue after saving the record in the transaction: its commit is what sends it.
  # With no transaction open, the notice is sent at once.
  module DeferredNotices
    extend ActiveSupport::Concern

    REGISTRY = :moderate_deferred_notices

    included do
      after_commit :deliver_deferred_notices
      after_rollback :discard_deferred_notices
    end

    class << self
      # { [model name, id] => [[transaction state, notice], …] }, per thread/fiber.
      def registry
        ActiveSupport::IsolatedExecutionState[REGISTRY] ||= Hash.new { |hash, key| hash[key] = [] }
      end

      def queue(key, state, notice)
        registry[key] << [state, notice]
      end

      # The committed entries for `key`, removed from the registry. Entries whose
      # transaction is still open stay queued for its commit.
      def take_committed(key)
        entries = registry.fetch(key, [])
        committed, pending = entries.partition { |state, _notice| state.committed? }
        pending.empty? ? registry.delete(key) : registry[key] = pending
        committed.map(&:last)
      end

      # Drop every entry a rollback undid, for any row: nothing is kept for a change
      # that didn't happen, and nothing leaks.
      def discard_rolled_back
        registry.each_value { |entries| entries.reject! { |state, _notice| state.rolledback? } }
        registry.delete_if { |_key, entries| entries.empty? }
      end
    end

    def after_commit_notice(&notice)
      transaction = self.class.connection.current_transaction
      return tap { notice.call } unless transaction.open?

      DeferredNotices.queue(deferred_notice_key, transaction.state, notice)
      self
    end

    private

    def deferred_notice_key
      [self.class.base_class.name, id]
    end

    def deliver_deferred_notices
      DeferredNotices.take_committed(deferred_notice_key).each(&:call)
    end

    def discard_deferred_notices
      DeferredNotices.discard_rolled_back
    end
  end
end
