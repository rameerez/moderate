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
  #            field actually changed and the value trips the filter) a
  #            `Moderate::Flag` is filed for review.
  #
  # WHY :flag lives in after_commit and not in a validator (this is the whole
  # reason `:flag` is a `moderates` mode you can't hand-roll with `validates`):
  # validators must be side-effect-free, and a Flag created inside a transaction
  # that later rolls back would silently vanish — you'd think you flagged something
  # you didn't. `after_commit` guarantees the surrounding transaction committed
  # before we write the Flag. See docs/configuration.md ("`:flag` never lives in a
  # validator").
  module ContentFilterable
    extend ActiveSupport::Concern

    included do
      # The set of filtered field names (Strings), inherited via class_attribute so
      # STI subclasses keep their parent's filtered fields. Accumulates across
      # multiple `moderates`/`moderates_fields` declarations on the same class.
      class_attribute :moderation_filtered_fields, instance_writer: false, default: [].freeze

      validate :moderate_blocked_fields_must_be_allowed
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
        next if value.blank?

        result = Moderate.classify(value, policy: policy)
        errors.add(field, :objectionable_content) if result.flagged?
      end
    end

    # :flag enforcement — an after_commit side effect that files a Moderate::Flag.
    #
    # We only act when the field actually CHANGED on this commit (re-saving an
    # untouched record must not re-flag it and spam the queue), and we wrap each
    # field in `begin/ensure` so a clean-up hook (`moderation_field_committed`)
    # always runs even if classification raises — important for the attachment
    # seam below, where a host sets a one-shot "changed" flag it must clear.
    def moderate_flag_filtered_fields
      moderation_filtered_fields.each do |field|
        policy = Moderate.filter_policy_for(self, field)
        next unless policy.flag?
        next unless moderation_field_changed_for_commit?(field)

        begin
          value = moderation_field_value(field)
          next if value.blank?

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
    # columns AND non-column content (e.g. an Active Storage attachment), without
    # the concern knowing anything about attachments. Defaults handle the common
    # "it's a text attribute" case; a host overrides them for richer content.

    # The value to classify for `field`. Default: the attribute reader. Override to
    # return, say, an attachment's blob/URL for an image adapter. The classifier
    # (text or image) is whatever the field's policy adapter is.
    def moderation_field_value(field)
      public_send(field)
    end

    # Did `field` change on the just-committed save? Default: ask ActiveRecord's
    # dirty tracking (`saved_change_to_attribute?`). We guard with `respond_to?`
    # so the concern also works on a PORO/ActiveModel object that lacks AR dirty
    # tracking (in which case we conservatively assume it changed). Override for
    # non-attribute content (e.g. track an attachment's "was replaced" flag).
    def moderation_field_changed_for_commit?(field)
      if respond_to?(:saved_change_to_attribute?)
        saved_change_to_attribute?(field)
      elsif respond_to?(:"saved_change_to_#{field}?")
        public_send(:"saved_change_to_#{field}?")
      else
        true
      end
    end

    # Per-field clean-up after the commit-time flag attempt (success OR failure).
    # No-op by default; the attachment seam overrides it to reset a one-shot
    # "changed" flag it set during the save.
    def moderation_field_committed(_field)
      nil
    end
  end
end
