# frozen_string_literal: true

module Moderate
  # Pre-publication content filtering for a model's fields. Backs the `moderates`
  # macro (and its documented equivalent, `include Moderate::ContentFilterable` +
  # `moderates_fields :body`).
  #
  # For each declared field the concern resolves the field's FilterPolicy (via
  # `Moderate.filter_policy_for`, which walks the ancestor chain so an STI parent's
  # policy covers its children) and enforces it in one of two ways, by mode:
  #
  #   :off   — nothing.
  #   :block — a VALIDATION. If the classifier flags the value, the save is
  #            rejected with `errors.add(field, :objectionable_content)`. Runs
  #            synchronously, so it only works with a synchronous adapter — the
  #            Configuration validates that invariant (README: ":block requires a
  #            synchronous adapter").
  #   :flag  — an AFTER_COMMIT side effect. The save SUCCEEDS, then (only if the
  #            field actually changed) the value is classified and a
  #            `Moderate::Flag` is filed when it trips. HOW it's classified
  #            depends on the adapter: a synchronous adapter (the wordlist)
  #            classifies inline right here; an ASYNC adapter (`synchronous? ==
  #            false` — any remote moderation API) is routed through
  #            `Moderate::ClassifyJob`, because blocking network I/O must never
  #            run inside the request that saved the content. The job re-reads
  #            the current value and files the Flag itself.
  #
  # WHY :flag lives in after_commit and not in a validator (this is the whole
  # reason `:flag` is a `moderates` mode you can't hand-roll with `validates`):
  # validators must be side-effect-free, and a Flag created inside a transaction
  # that later rolls back would silently vanish — you'd think you flagged something
  # you didn't. `after_commit` guarantees the surrounding transaction committed
  # before we write the Flag (and that a ClassifyJob never races a rollback). See
  # docs/configuration.md ("`:flag` never lives in a validator").
  #
  # ACTIVE STORAGE ATTACHMENTS work out of the box: `moderates :avatar, with:
  # :your_image_adapter, mode: :flag` on a `has_one_attached :avatar` model needs
  # no extra wiring. AR dirty tracking can't see attachment writes — and Active
  # Storage drops `attachment_changes` in its own after_commit — so the concern
  # snapshots "these filtered attachments changed" in a before_save and consumes
  # the snapshot at commit time. The overridable seam below still exists for
  # richer cases (derived values, non-AS blobs).
  #
  # An attachment is classified only once its file is on the storage service, and
  # it is classified even when the upload fails. Active Storage uploads a newly
  # attached file in ITS after_commit (in whichever order the two after_commits were
  # declared), so the concern hooks that upload itself, from before_save:
  #
  #   1. just before the upload starts, a ClassifyJob is enqueued UPLOAD_WAIT seconds
  #      out: the durable intent. If the upload raises, or the process dies, that job
  #      still runs, waits (bounded) for the file, and classifies it or audits
  #      `classification_skipped`;
  #   2. once the upload returns, the field is classified right away when its files
  #      are on the service: inline for a synchronous adapter, by an immediate
  #      ClassifyJob for an async one. A direct upload (an attached blob or signed
  #      id, whose `upload` is a no-op) may not be there yet; then the job from step
  #      1 takes it.
  #
  # Whichever classifies first claims the files (a moderate_classifications row,
  # Moderate::Attachments), calls the adapter outside any lock and records the
  # result; the rest find the claim or the record and stop, so a field is classified
  # once per set of files. An adapter that raises leaves its claim until
  # `config.classification_claim_ttl` runs out and schedules no retry itself: the
  # guard job, a job's recheck at the claim's expiry, or a new save takes it over.
  module ContentFilterable
    extend ActiveSupport::Concern

    # Extended onto one pending Active Storage attachment change (the object
    # `has_one_attached` / `has_many_attached` upload from their after_commit), so
    # the record hears just before and just after that change uploads its files.
    # Per object, never a global patch. A failure of ours never breaks the upload.
    module AfterUpload
      def upload(...)
        moderate_notify(:moderate_upload_starting)
        result = super
        moderate_notify(:moderate_upload_finished)
        result
      end

      def moderate_watch(record, field)
        (@moderate_watchers ||= {})[field.to_s] = record
      end

      private

      def moderate_notify(event)
        Array(@moderate_watchers).each do |field, record|
          record.send(event, field)
        rescue StandardError => error
          Moderate.audit(
            :classification_skipped,
            subject: record,
            payload: { field: field, reason: "filter_error", error_class: error.class.name,
                       summary: "#{record.class.name}##{field}: #{event} raised #{error.class}" }
          )
        end
      end
    end
    private_constant :AfterUpload

    included do
      # The set of filtered field names (Strings), inherited via class_attribute so
      # STI subclasses keep their parent's filtered fields. Accumulates across
      # multiple `moderates`/`moderates_fields` declarations on the same class.
      class_attribute :moderation_filtered_fields, instance_writer: false, default: [].freeze

      validate :moderate_blocked_fields_must_be_allowed
      # Snapshot attachment writes BEFORE Active Storage's own save callbacks
      # clear `attachment_changes` — by after_commit they're gone (see
      # activestorage's Attached::Model). One-shot; consumed + cleared below.
      before_save :moderate_snapshot_attachment_changes
      after_commit :moderate_flag_filtered_fields
    end

    class_methods do
      # Register one or more fields for filtering. Additive and de-duplicated, so
      # `moderates :a; moderates :b` and `moderates_fields :a, :b` are equivalent.
      # The PER-FIELD adapter/mode (the `with:`/`mode:` of the `moderates` macro)
      # is recorded separately as a Configuration FilterPolicy by the macro; this
      # method only tracks WHICH fields to run on commit/validate.
      def moderates_fields(*fields)
        self.moderation_filtered_fields =
          (moderation_filtered_fields + fields.map(&:to_s)).uniq.freeze
      end
    end

    private

    # :block enforcement — a validation. We deliberately skip :flag fields here
    # (their work happens after_commit) and blank values (nothing to classify).
    #
    # `:block` lets nothing in unverified: an attachment that points at a stored blob
    # whose file isn't on the service (a direct upload that hasn't finished) fails
    # with `:upload_not_finished` instead of being classified without its file.
    def moderate_blocked_fields_must_be_allowed
      moderation_filtered_fields.each do |field|
        policy = Moderate.filter_policy_for(self, field)
        next unless policy.block?

        value = moderation_field_value(field)
        next if moderation_value_blank?(value)
        next errors.add(field, :upload_not_finished) if Moderate::Attachments.upload_unfinished?(value)

        result = Moderate.classify(value, policy: policy)
        errors.add(field, :objectionable_content) if result.flagged?
      end
    end

    # :flag enforcement — an after_commit side effect that files a Moderate::Flag
    # (inline for synchronous adapters; via Moderate::ClassifyJob for async ones).
    #
    # We only act when the field actually CHANGED on this commit (re-saving an
    # untouched record must not re-flag it and spam the queue). A field whose upload
    # the concern is watching is left to that upload's hooks (see AfterUpload).
    def moderate_flag_filtered_fields
      moderation_filtered_fields.each do |field|
        next if @moderate_watched_uploads&.include?(field)

        policy = Moderate.filter_policy_for(self, field)
        next unless policy.flag?
        next unless moderation_field_changed_for_commit?(field)

        moderate_flag_field(field, policy)
      end
    end

    # Just before Active Storage uploads `field`'s files: enqueue the job that
    # classifies them even if this upload fails (see the module comment).
    def moderate_upload_starting(field)
      policy = Moderate.filter_policy_for(self, field)
      return unless policy.flag? && moderation_field_changed_for_commit?(field)

      (@moderate_guarded_uploads ||= Set.new) << field
      Moderate::ClassifyJob.set(wait: Moderate::ClassifyJob::UPLOAD_WAIT)
        .perform_later(self, field, blob_ids: Moderate::Attachments.blob_ids(moderation_field_value(field)))
    end

    # The upload returned: classify now if the files are there (the guard job takes
    # them otherwise).
    def moderate_upload_finished(field)
      @moderate_watched_uploads&.delete(field)
      return moderation_field_committed(field) unless @moderate_guarded_uploads&.delete?(field)

      moderate_flag_field(field, Moderate.filter_policy_for(self, field), guarded: true)
    end

    # Classify one changed field and file its Flag. Wrapped in `ensure` so the
    # clean-up hook (`moderation_field_committed`) always runs even if
    # classification raises — that hook is what clears the one-shot attachment
    # snapshot.
    #
    # An attachment whose files aren't all on the service yet is never classified
    # here: the after-upload guard job takes it (`guarded:`), or a ClassifyJob that
    # waits for it is enqueued now.
    def moderate_flag_field(field, policy, guarded: false)
      value = moderation_field_value(field)
      attachment = Moderate::Attachments.attachment?(value)
      return if attachment && moderation_value_blank?(value)

      if attachment && !Moderate::Attachments.uploaded?(value)
        Moderate::ClassifyJob.perform_later(self, field, blob_ids: Moderate::Attachments.blob_ids(value)) unless guarded
        return
      end

      # ASYNC adapters (remote moderation APIs) never classify inline — a network
      # call in the request's after_commit would stall the response for as long
      # as the provider takes. ClassifyJob re-reads the value at run time (so it
      # always classifies what's actually persisted) and files the Flag through the
      # same Flag.flag! builder.
      if Moderate.config.adapter_async?(policy.adapter)
        blob_ids = (Moderate::Attachments.blob_ids(value) if attachment)
        Moderate::ClassifyJob.perform_later(self, field, blob_ids: blob_ids)
        return
      end

      return if moderation_value_blank?(value)
      return moderate_classify_attachment(field, policy) if attachment

      result = Moderate.classify(value, policy: policy)
      return unless result.flagged?

      moderate_file_flag(field, policy, value, result)
    ensure
      moderation_field_committed(field)
    end

    # Claim, classify outside any lock, complete (Moderate::Attachments): the guard
    # job and this path never both classify the same files, and a slow adapter never
    # holds this record's row.
    def moderate_classify_attachment(field, policy)
      Moderate::Attachments.classify_once(
        self, field,
        owner: SecureRandom.uuid,
        read: -> { self.class.unscoped.find_by(id: id)&.send(:moderation_field_value, field) },
        classify: ->(value) { Moderate.classify(value, policy: policy) },
        file: ->(value, result) { moderate_file_flag(field, policy, value, result) }
      )
    end

    def moderate_file_flag(field, policy, value, result)
      Moderate::Flag.flag!(
        flaggable: self,
        field: field,
        # `reported_owner` comes from Moderate::Reportable. A filterable model is
        # usually also reportable; if it isn't — or its owner isn't a person
        # (Moderate.responsible_user) — the owner is simply nil (the flag still
        # lands in the queue, just unattributed).
        owner: Moderate.responsible_user(self),
        source: result.source,
        mode: policy.mode,
        # Cap the stored excerpt so we never balloon a row with a huge body; 500
        # chars is plenty of context for a reviewer.
        excerpt: value.to_s.truncate(500),
        categories: result.categories,
        scores: result.scores,
        # Keep the policy that produced the flag alongside the adapter's raw
        # payload, so the queue can show "flagged by <adapter> under
        # <Class>#<field>" and an auditor can inspect the untouched response.
        context: {
          raw: result.raw,
          policy: { class_name: policy.class_name, field: policy.field, mode: policy.mode.to_s }
        }
      )
    end

    # --- Overridable field seam -----------------------------------------------
    #
    # These three methods are the seam that lets one concern filter BOTH plain text
    # columns AND non-column content, without hosts having to re-plumb the common
    # cases. Defaults handle text attributes AND Active Storage attachments; a
    # host overrides them for anything richer (derived values, external blobs).

    # The value to classify for `field`. Default: the attribute reader — which for
    # a `has_one_attached` field returns the `ActiveStorage::Attached` proxy, the
    # natural input for an image adapter (it can read `.record`, `.blob`,
    # `.variant(...)`, or download bytes as it sees fit).
    def moderation_field_value(field)
      public_send(field)
    end

    # Did `field` change on the just-committed save? Defaults, in order:
    #   1. the attachment snapshot taken in before_save (AR dirty tracking can't
    #      see attachment writes, and Active Storage drops `attachment_changes`
    #      in its own after_commit — hence the one-shot snapshot),
    #   2. ActiveRecord's own dirty tracking (`saved_change_to_attribute?`),
    #   3. `true` for a PORO/ActiveModel object with no dirty tracking at all —
    #      the conservative assumption.
    # Override for non-attribute content the defaults can't see.
    def moderation_field_changed_for_commit?(field)
      return true if @moderate_changed_attachment_fields&.include?(field.to_s)

      if respond_to?(:saved_change_to_attribute?)
        saved_change_to_attribute?(field)
      elsif respond_to?(:"saved_change_to_#{field}?")
        public_send(:"saved_change_to_#{field}?")
      else
        true
      end
    end

    # Per-field clean-up after the commit-time flag attempt (success OR failure).
    # Consumes the one-shot attachment snapshot; override-and-super if you track
    # extra per-field state of your own.
    def moderation_field_committed(field)
      @moderate_changed_attachment_fields&.delete(field.to_s)
      nil
    end

    # before_save: record which FILTERED fields have a pending attachment write on
    # this save, and watch the upload of each (AfterUpload). `attachment_changes`
    # only exists on Active Storage models — plain models skip straight through. A
    # removal (`avatar = nil`) is a change with nothing to upload, so nothing to watch.
    def moderate_snapshot_attachment_changes
      return unless respond_to?(:attachment_changes)

      @moderate_watched_uploads = Set.new
      moderation_filtered_fields.each do |field|
        change = attachment_changes[field]
        next if change.nil?

        (@moderate_changed_attachment_fields ||= Set.new) << field
        next unless change.respond_to?(:upload)

        change.extend(AfterUpload) unless change.is_a?(AfterUpload)
        change.moderate_watch(self, field)
        @moderate_watched_uploads << field
      end
      nil # a callback's return value never halts the save (only `throw :abort` does)
    end

    # Blank check that can see through an `ActiveStorage::Attached` proxy — an
    # attachment with nothing attached must read as "nothing to classify"
    # (Object#blank? can't tell: the proxy is truthy and has no #empty?).
    def moderation_value_blank?(value)
      return !value.attached? if value.respond_to?(:attached?)

      value.blank?
    end
  end
end
