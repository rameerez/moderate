# frozen_string_literal: true

module Moderate
  # Notices that must not reach anyone before the change they announce is durable.
  #
  # A service saves a record inside a transaction, then queues what to send on that
  # record with `after_commit_notice { … }`. The record's own `after_commit` sends it
  # when the OUTERMOST transaction commits — the gem's, or a host's around it — and
  # `after_rollback` drops it, so a host that decides inside a transaction of its own
  # and then rolls it back never emails a decision, a receipt or a block that didn't
  # happen. This is plain Active Record transactional callbacks, so Rails 7.1, 7.2 and
  # 8.x behave the same.
  #
  # Queue the notice on the instance that was saved in the transaction, after the
  # save: transactional callbacks run on the instance Active Record tracked for it.
  module DeferredNotices
    extend ActiveSupport::Concern

    included do
      after_commit :deliver_deferred_notices
      after_rollback :discard_deferred_notices
    end

    def after_commit_notice(&block)
      (@moderate_deferred_notices ||= []) << block
      self
    end

    private

    def deliver_deferred_notices
      notices = @moderate_deferred_notices
      @moderate_deferred_notices = nil
      Array(notices).each(&:call)
    end

    def discard_deferred_notices
      @moderate_deferred_notices = nil
    end
  end
end
