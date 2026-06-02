# frozen_string_literal: true

module Moderate
  # The contract a model opts into to become *reportable* — i.e. a piece of
  # user-generated content (a comment, a listing, a profile) that another user (or
  # a public DSA notice) can file a report against.
  #
  # Plain Rails polymorphism answers "what row was reported?" via the
  # `Moderate::Report#reportable` association. This concern answers the
  # Trust & Safety questions that polymorphism *can't*:
  #
  #   - which fields of the record may be reported (`reportable_fields`)
  #   - who is *responsible* for the content (`reported_owner`) — the person a
  #     decision's statement of reasons must reach (DSA Art. 17) and who a ban
  #     would apply to
  #   - what the moderation queue should *call* this item (`moderation_label`)
  #   - what immutable evidence to snapshot at report time so it survives an edit
  #     or delete (`moderation_snapshot`)
  #   - what a moderator may *remove* without nuking the whole record
  #     (`remove_reported_field!`)
  #   - whether a given viewer is even allowed to report it (`report_visible_to?`)
  #
  # WHY a concern and not just config: these answers are intrinsic to each model
  # (only the Listing knows its title is reportable but its internal SKU isn't),
  # so they belong ON the model. Hosts override the handful of methods that need
  # domain knowledge; everything else has a safe default.
  #
  # Regulatory grounding for why a reportable contract has to exist at all:
  #   - Apple App Store Review Guideline 1.2 requires a way to report UGC and a
  #     mechanism to remove offending content:
  #     https://developer.apple.com/app-store/review/guidelines/#user-generated-content
  #   - Google Play UGC policy requires in-app reporting and ongoing moderation:
  #     https://support.google.com/googleplay/android-developer/answer/9876937
  #   - EU DSA Art. 16 (notice & action) presupposes that reported items can be
  #     identified, snapshotted, and acted on:
  #     https://eur-lex.europa.eu/eli/reg/2022/2065/oj
  #
  # The documented include form is `include Moderate::Reportable` +
  # `reportable_fields :a, :b`; the `has_reportable_content :a, :b` macro is exact sugar.
  module Reportable
    extend ActiveSupport::Concern

    included do
      # Reports filed against THIS record. Kept on the public `reports` reader
      # because the README promises `listing.reports`, and because a reportable
      # model should read naturally in host code. Reports are legal/evidentiary,
      # so hard-deleting the content detaches rather than destroys them.
      has_many :reports,
        as: :reportable,
        class_name: "Moderate::Report",
        dependent: :nullify

      # The whitelist of reportable field names, stored as frozen Strings. A
      # `class_attribute` (not a plain constant) so it inherits down an STI tree
      # AND can be overridden per subclass without mutating the parent's list.
      # Empty default = "the whole record is reportable, no specific field."
      class_attribute :moderation_reportable_fields, instance_writer: false, default: [].freeze

      # Self-register in the gem's reportable registry the moment the concern is
      # included, so `Moderate.reportable_classes` is auto-discovered with NO
      # manual list to maintain (README: "Reportable classes are auto-discovered
      # from the `has_reportable_content` macro — no manual registry."). We register the class
      # NAME (the registry stores strings and constantizes lazily) so we never pin
      # the class across a Zeitwerk reload in development.
      Moderate.register_reportable(self)
    end

    class_methods do
      # Declare (or read) the reportable fields. Idempotent and additive-free:
      # the last declaration wins for THIS class (it doesn't merge with the
      # inherited value), matching how a host expects `reportable_fields :title`
      # to mean exactly `["title"]`. Called with no args, it's a reader.
      #
      #   reportable_fields :title, :description   # writer
      #   reportable_fields                         # => ["title", "description"]
      def reportable_fields(*fields)
        self.moderation_reportable_fields = fields.map(&:to_s).freeze if fields.any?
        moderation_reportable_fields
      end
    end

    # Is `field` one a reporter is allowed to name? Two cases:
    #
    #   - A BLANK field is ALWAYS allowed — it means "report the whole record," which
    #     is valid whether or not the model declared specific reportable fields. (A
    #     user tapping "Report this comment" doesn't name a field; only the public DSA
    #     notice / a field-targeted in-app flow does.) So a Comment that declares
    #     `has_reportable_content :body` can still be reported as a whole with a nil field.
    #
    #   - A NAMED field must be in the whitelist. With no fields declared, the
    #     whitelist is empty, so any named field is rejected (there's nothing to
    #     target field-by-field on a bare-`has_reportable_content` record).
    #
    # This is the authorization gate the Report model and the report controller both
    # consult before accepting a `reported_field`.
    def reportable_field_allowed?(field)
      field_s = field.to_s
      return true if field_s.empty?

      self.class.reportable_fields.include?(field_s)
    end

    # WHO is responsible for this content — the account a decision's statement of
    # reasons reaches (DSA Art. 17) and the user a ban would apply to.
    #
    # NO default: a model that can be reported MUST tell the gem who's behind it,
    # because guessing wrong here means notifying or banning the wrong person.
    # We raise a NotImplementedError naming the class so the omission is loud at
    # the first report, not silent. (A `User` model with `has_reporting_and_blocking` is itself
    # reportable and returns `self` — see Moderate::Actor.)
    def reported_owner
      raise NotImplementedError,
        "#{self.class.name} is reportable but doesn't define #reported_owner. " \
        "Return the user responsible for this content (the one a decision notifies " \
        "and a ban applies to), e.g. `def reported_owner = user`."
    end

    # The human-readable name the moderation queue shows for this item. Defaults
    # to Rails' own `to_s` (usually "#<Comment id: 42>"); override for something an
    # admin can act on at a glance, e.g. `def moderation_label = "Comment #{id}"`.
    def moderation_label
      to_s
    end

    # The immutable evidence text to capture for `field` at report time, so the
    # report survives the content being edited or deleted. The Report model calls
    # this in its `before_validation :capture_snapshot` (DSA-grade evidence
    # preservation). Defaults to nil; override to return the actual field text
    # (e.g. `public_send(field)`) or a description of a non-text attachment.
    #
    # NAMED `moderation_snapshot` per the gem's public reportable contract; takes
    # the field so a multi-field record can snapshot the specific thing reported.
    def moderation_snapshot(_field)
      nil
    end

    # Remove the reported `field` as an enforcement action — WITHOUT destroying the
    # whole record (a moderator removing one objectionable photo shouldn't delete
    # the whole listing). Returns truthy if something was actually removed (so the
    # decision service knows whether to fire the `content_removed` event).
    #
    # Defaults to a no-op returning false: a model that hasn't opted into
    # field-level removal simply reports "nothing removed," and the moderator falls
    # back to other actions. Override to purge an attachment, blank a column, etc.
    def remove_reported_field!(_field)
      false
    end

    # Companion query to `remove_reported_field!`: CAN this specific `field` be
    # removed on this record? An admin UI uses it to decide whether to OFFER a
    # "remove content" action at all. Without it, a host that only removes SOME
    # fields (e.g. an avatar but not a display name) would render a remove button
    # that always fails when the moderator clicks it on a non-removable field.
    #
    # Defaults to false (mirrors the no-op `remove_reported_field!`). Override it
    # alongside `remove_reported_field!` and have the latter reuse it, so the
    # "can I?" answer and the "do it" action never drift apart.
    def removable_reported_field?(_field)
      false
    end

    # Visibility/authorization gate for the report affordance: should `viewer` be
    # offered a "report this" control for `field`? The default enforces two rules:
    #
    #   1. the field must be reportable (`reportable_field_allowed?`), and
    #   2. you can't report YOUR OWN content — the affordance is hidden from the
    #      content's owner, so an author never sees "Report" on their own post. We
    #      compare the viewer to this content's `reported_owner` (the Reportable
    #      contract's "who is responsible" answer).
    #
    # The `moderate_report_link` helper renders nothing when this is false, and the
    # report controller redirects. Hosts can override for richer rules. (A User with
    # `has_reporting_and_blocking` overrides this in Moderate::Actor to compare ids directly,
    # since a user IS its own owner.)
    def report_visible_to?(viewer, field:)
      return false unless reportable_field_allowed?(field)
      return false if viewer.present? && moderation_owner_is?(viewer)

      true
    end

    # Open reports filed against this record, optionally narrowed to one field.
    # Hosts can use this when they need the actual relation (queue previews,
    # counters, "already reported" affordances) instead of just a boolean.
    def open_reports(field = nil)
      moderation_scope_by_field(reports.open, :reported_field, field)
    end

    # Has this record received any open reports? This is the public predicate
    # documented beside `reports` in the README.
    def reported?(field = nil)
      open_reports(field).exists?
    end

    # All auto-filter/manual flags against this record, optionally narrowed to a
    # field. We keep this as a method instead of a `has_many :flags` association:
    # `flags` is a common host-model word, while `flagged?` is the public DX.
    def moderation_flags(field = nil)
      moderation_scope_by_field(
        Moderate::Flag.where(flaggable: self),
        :field,
        field
      )
    end

    # Pending flags are the "allowed through, awaiting review" state a host may
    # want to surface near user-generated content.
    def pending_moderation_flags(field = nil)
      moderation_flags(field).pending
    end

    # Has this record been flagged and not yet resolved/dismissed? Optionally
    # pass a field (`listing.flagged?(:description)`) for field-level UI.
    def flagged?(field = nil)
      pending_moderation_flags(field).exists?
    end

    # --- Route descriptor hooks -----------------------------------------------
    #
    # The gem is UI-agnostic and doesn't know the host's routes, so a reportable
    # tells the gem how to build the few URLs/paths that decision notices and the
    # public DSA notice form need. Each receives the host's route proxy (whatever
    # responds to the app's `*_url`/`*_path` helpers — typically the controller or
    # `Rails.application.routes.url_helpers`) and returns a string or nil.
    #
    # All default to nil — the gem treats a missing route as "no link available"
    # and degrades gracefully (e.g. the statement of reasons just omits the link,
    # the post-report redirect falls back to the app root). Hosts override only the
    # ones their flows actually surface.

    # The public, canonical URL of this content — what a DSA Art. 16 notice records
    # as the precise location of the allegedly illegal content, and what a
    # statement of reasons points the affected user to.
    def moderation_subject_url(_routes)
      nil
    end

    # Where to send a user *back to* after they file a report on this content
    # (e.g. the content's own page). Falls back to the app root when nil.
    def moderation_return_path(_routes)
      nil
    end

    # The admin/back-office path for this content, so the moderation queue can deep
    # link a reviewer straight to the item under review.
    def moderation_admin_path(_routes)
      nil
    end

    private

    # Is `viewer` the user responsible for this content? Used by the default
    # `report_visible_to?` to hide the report affordance from the content's own owner.
    #
    # We resolve ownership via the Reportable contract's `reported_owner`, but guard
    # it carefully: `reported_owner` deliberately RAISES NotImplementedError on a
    # reportable that hasn't defined it (so the omission is loud at report time). A
    # visibility check, by contrast, must never blow up a view — so we rescue that
    # case and treat "unknown owner" as "not the viewer" (show the link; the write
    # path will still surface the missing-owner error if they actually report). We
    # compare by primary key when both sides are AR records, else by object equality.
    def moderation_owner_is?(viewer)
      owner = reported_owner
      return false if owner.nil?

      if owner.respond_to?(:id) && viewer.respond_to?(:id)
        owner.id == viewer.id && owner.class == viewer.class
      else
        owner == viewer
      end
    rescue NotImplementedError
      false
    end

    def moderation_scope_by_field(scope, column, field)
      field_s = field.to_s.squish
      return scope if field_s.blank?

      scope.where(column => field_s)
    end
  end
end
