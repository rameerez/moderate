# frozen_string_literal: true

module Moderate
  # The background worker for ASYNCHRONOUS filter adapters (a remote moderation API
  # such as the OpenAI or Rekognition reference adapters in examples/, or a host's
  # own classifier) running in :flag mode.
  #
  # ── Why a job exists at all ──────────────────────────────────────────────────
  # An async adapter does blocking I/O (a moderation API call), which must never run
  # inside the request that saved the content — and CANNOT run inside a validator or
  # an after_commit callback without stalling the write. So the :flag path works in
  # two halves:
  #   1. The model's filter concern (`moderates :field`) lets the write succeed, then
  #      in an after_commit hook enqueues THIS job for any field whose policy uses an
  #      async adapter. (Synchronous adapters like :wordlist skip the job — the
  #      concern classifies inline and files the Flag directly.)
  #   2. This job re-reads the saved value, classifies it through the adapter, and —
  #      if the content is flagged — files (or updates) a Moderate::Flag for the
  #      moderation queue.
  #
  # ── Re-reading the value (deliberate) ────────────────────────────────────────
  # The job is handed the RECORD (GlobalID-serialized by ActiveJob) and the FIELD
  # NAME, not the raw text/image — so it always classifies the CURRENT persisted
  # value. If the record was edited or deleted between enqueue and run, we classify
  # what's actually there now (or skip a vanished record), never a stale snapshot.
  #
  # ── One flag per run ─────────────────────────────────────────────────────────
  # Flag creation goes through `Moderate::Flag.flag!`, the single builder shared by
  # the synchronous and asynchronous paths, and it is the job's last step, so a job
  # that fails earlier (the adapter's network call) and is retried files one flag.
  # `flag!` always creates: two runs for the same content (two saves, or a host that
  # also enqueues the job itself) file two flags, both in the queue.
  #
  # ── An attachment whose file isn't on the service yet ────────────────────────
  # For an attachment the filter enqueues this job before Active Storage uploads
  # the file (the guard: it runs even if the upload fails) and, once the upload
  # returns, classifies right away (see Moderate::ContentFilterable). When the job
  # runs, a blob can be missing: the upload failed or is still running, a direct
  # upload hasn't finished, a replica lags. The job then re-enqueues itself,
  # waiting UPLOAD_WAIT × attempt seconds, up to UPLOAD_ATTEMPTS runs in all, and
  # gives up with a `classification_skipped` audit event. It never hands an adapter
  # a file that isn't there.
  #
  # `blob_ids:` names the files the job was enqueued for: if the field holds other
  # files by the time it runs, the newer change has its own job and this one stops.
  # A field already classified for exactly these files (Moderate::Attachments marks
  # the blobs) is not classified again.
  #
  # ── Base class ───────────────────────────────────────────────────────────────
  # We subclass `ActiveJob::Base` directly (not the host's ApplicationJob) so the gem
  # doesn't depend on a constant that lives in the host app — the same reason the
  # rest of the gem stays host-agnostic. The host configures the queue adapter,
  # retries, and queue name globally as usual.
  class ClassifyJob < ActiveJob::Base
    # The :default queue. Moderation flagging is important but not latency-critical
    # (the content is already published in :flag mode); a host that wants it elsewhere
    # says so in an initializer: `Moderate::ClassifyJob.queue_as :low`.
    queue_as :default

    # Seconds to wait before the next look at a blob that isn't uploaded yet,
    # multiplied by the attempt number (5s, 10s, 15s, 20s: under a minute in all).
    UPLOAD_WAIT = 5
    # Runs of this job, the first included, before it gives up on such a blob.
    UPLOAD_ATTEMPTS = 5

    # @param record [ActiveRecord::Base] the flaggable record (any Moderate::Reportable).
    # @param field  [String, Symbol] the field whose value to classify.
    # @param adapter [String, Symbol, nil] optional explicit adapter name; when nil,
    #   the field's resolved FilterPolicy (or the global default) decides.
    # @param upload_attempt [Integer] which look at a not-yet-uploaded attachment
    #   this is (the job sets it when it re-enqueues itself; callers leave it).
    # @param blob_ids [Array<Integer>, nil] the attachment's blobs when enqueued.
    def perform(record, field, adapter: nil, upload_attempt: 1, blob_ids: nil)
      # The record may have been destroyed between enqueue and execution — nothing
      # to classify, nothing to flag. (ActiveJob raises DeserializationError for a
      # GlobalID that no longer resolves; that's rescued at the framework level, but
      # we also guard a nil here defensively.)
      return if record.nil?

      field = field.to_s
      policy = resolve_policy(record, field, adapter)

      # If the field's policy is :off (e.g. it was reconfigured to off after the job
      # was enqueued), there's nothing to do.
      return if policy.respond_to?(:off?) && policy.off?

      value = field_value(record, field)
      return if blank?(value)

      attachment = Moderate::Attachments.attachment?(value)
      if attachment
        return if blob_ids && Moderate::Attachments.blob_ids(value) != Array(blob_ids).sort
        return if Moderate::Attachments.classified?(record, field, value)
        return wait_for_upload(record, field, adapter, upload_attempt, blob_ids) unless Moderate::Attachments.uploaded?(value)
      end

      result = Moderate.classify(value, policy: policy)
      file_flag(record, field, policy, result, value) if result.flagged?
      Moderate::Attachments.mark_classified!(record, field, value) if attachment
    end

    private

    # Resolve the FilterPolicy for this record/field. If an explicit adapter name was
    # passed (the enqueuer already knew it), prefer the field's declared policy but
    # fall back to the global resolution — `Moderate.filter_policy_for` already walks
    # the ancestor chain and falls back to an :off policy, so this is always defined.
    def resolve_policy(record, field, adapter)
      policy = Moderate.filter_policy_for(record, field)
      return policy if adapter.nil?

      # An explicit adapter override: keep the resolved policy's class/field/mode but
      # swap in the requested adapter, so the job classifies with exactly the backend
      # the enqueuer intended even if config changed.
      Moderate::Configuration::FilterPolicy.new(
        class_name: policy.class_name, field: field,
        adapter: adapter.to_s.strip.downcase.to_sym, mode: policy.mode
      )
    end

    # File the Moderate::Flag via the shared builder. We pass exactly the
    # columns the install migration defines for moderate_flags. `Flag.flag!` owns the
    # `content_flagged` notify event so there's a single emission site across the
    # sync and async paths — the job doesn't fire it itself, to avoid double-notifying.
    #
    # `result.source` is the human-readable adapter NAME the spine stamped on the
    # Result (e.g. "openai"); the persisted `source` COLUMN, however, is constrained
    # to text_filter/image_filter/external_classifier/manual, which the adapter's own
    # Result already reflects via its `source_name`. We pass `result.source` and let
    # the model coerce/validate against the constraint.
    def file_flag(record, field, policy, result, value)
      Moderate::Flag.flag!(
        flaggable: record,
        field: field,
        owner: content_owner(record),
        source: result.source,
        mode: policy.respond_to?(:mode) ? policy.mode : :flag,
        categories: result.categories,
        scores: result.scores,
        excerpt: excerpt_for(value),
        context: flag_context(policy, result)
      )
    end

    # Who owns the flagged content. The Reportable concern defines `reported_owner`
    # (the "who's responsible" hook); we use it when present and degrade to nil
    # otherwise (the owner column is nullable — a flag with no resolvable owner is
    # still a valid queue item).
    def content_owner(record)
      Moderate.responsible_user(record)
    end

    # Diagnostic context persisted on the flag (the `context` jsonb column): the raw
    # provider payload (for audit/debugging) plus the policy that produced this flag.
    # Never relied on by the gem's own logic — purely for the human in the queue.
    def flag_context(policy, result)
      context = {}
      context[:raw] = result.raw unless result.raw.nil?
      context[:policy] = {
        class_name: policy.class_name, field: policy.field, mode: policy.mode.to_s
      }
      context
    end

    # A short, human-readable snippet of the offending value for the queue. We keep
    # it to 500 chars — enough context for a moderator, not
    # a full copy of a long document. An image value (not a String) gets stringified
    # to its reference, which is fine for the queue's "what was flagged" column.
    def excerpt_for(value)
      value.to_s[0, 500]
    end

    def wait_for_upload(record, field, adapter, attempt, blob_ids)
      if attempt < UPLOAD_ATTEMPTS
        self.class.set(wait: UPLOAD_WAIT * attempt)
          .perform_later(record, field, adapter: adapter, upload_attempt: attempt + 1, blob_ids: blob_ids)
        return
      end

      Moderate.audit(
        :classification_skipped,
        subject: record,
        payload: {
          field: field,
          reason: "attachment_not_uploaded",
          attempts: attempt,
          summary: "#{record.class.name}##{field} not classified: its file never reached the storage service"
        }
      )
    end

    def field_value(record, field)
      record.public_send(field)
    rescue NoMethodError
      nil
    end

    # Blank check without forcing an ActiveSupport dependency in the job's hot path
    # (ActiveSupport IS loaded in a Rails host, but #blank? on arbitrary values is
    # easy to reproduce and keeps the job self-contained).
    def blank?(value)
      return true if value.nil?
      # An ActiveStorage::Attached proxy with nothing attached is "blank" — the
      # attachment may have been purged between enqueue and run, and a plain
      # #empty?/#nil? probe can't see through the proxy.
      return !value.attached? if value.respond_to?(:attached?)
      return value.strip.empty? if value.is_a?(String)
      return value.empty? if value.respond_to?(:empty?)

      false
    end
  end
end
