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
  # Storage clears `attachment_changes` before after_commit — so the concern
  # snapshots "these filtered attachments changed" in a before_save and consumes
  # the snapshot at commit time. The overridable seam below still exists for
  # richer cases (derived values, non-AS blobs).
  module ContentFilterable
    extend ActiveSupport::Concern

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
    def moderate_blocked_fields_must_be_allowed
      moderation_filtered_fields.each do |field|
        policy = Moderate.filter_policy_for(self, field)
        next unless policy.block?

        value = moderation_field_value(field)
        next if moderation_value_blank?(value)

        result = Moderate.classify(value, policy: policy)
        errors.add(field, :objectionable_content) if result.flagged?
      end
    end

    # :flag enforcement — an after_commit side effect that files a Moderate::Flag
    # (inline for synchronous adapters; via Moderate::ClassifyJob for async ones).
    #
    # We only act when the field actually CHANGED on this commit (re-saving an
    # untouched record must not re-flag it and spam the queue), and we wrap each
    # field in `begin/ensure` so the clean-up hook (`moderation_field_committed`)
    # always runs even if classification raises — that hook is what clears the
    # one-shot attachment snapshot.
    def moderate_flag_filtered_fields
      moderation_filtered_fields.each do |field|
        policy = Moderate.filter_policy_for(self, field)
        next unless policy.flag?
        next unless moderation_field_changed_for_commit?(field)

        begin
          # ASYNC adapters (remote moderation APIs) never classify inline —
          # a network call in the request's after_commit would stall the
          # response for as long as the provider takes. ClassifyJob re-reads
          # the value at run time (so it always classifies what's actually
          # persisted) and files the Flag through the same Flag.flag! builder.
          if Moderate.config.adapter_async?(policy.adapter)
            Moderate::ClassifyJob.perform_later(self, field)
            next
          end

          value = moderation_field_value(field)
          next if moderation_value_blank?(value)

          result = Moderate.classify(value, policy: policy)
          next unless result.flagged?

          Moderate::Flag.flag!(
            flaggable: self,
            field: field,
            # `reported_owner` comes from Moderate::Reportable. A filterable model
            # is usually also reportable; if it isn't, the owner is simply nil
            # (the flag still lands in the queue, just unattributed).
            owner: (reported_owner if respond_to?(:reported_owner)),
            source: result.source,
            mode: policy.mode,
            # Cap the stored excerpt so we never balloon a row with a huge body;
            # 500 chars is plenty of context for a reviewer.
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
        ensure
          moderation_field_committed(field)
        end
      end
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
    #      see attachment writes, and Active Storage clears `attachment_changes`
    #      before after_commit — hence the one-shot snapshot),
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

    # before_save: record which FILTERED fields have a pending attachment write
    # on this save. `attachment_changes` only exists on Active Storage models —
    # plain models skip straight through.
    def moderate_snapshot_attachment_changes
      return true unless respond_to?(:attachment_changes)

      moderation_filtered_fields.each do |field|
        next unless attachment_changes.key?(field)

        (@moderate_changed_attachment_fields ||= Set.new) << field
      end
      true # never halt the save chain
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
