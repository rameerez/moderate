# frozen_string_literal: true

module Moderate
  # The "person who acts" in the Trust & Safety system: the model that reports
  # other content, blocks other actors, gets reported, gets banned. Backs the
  # `participates_in_moderation` macro (and its documented equivalent,
  # `include Moderate::Actor`).
  #
  # This is the one model the gem treats as the actor/identity, configured via
  # `config.user_class`. There's normally exactly one such model per app ("User",
  # "Account", "Member"), and it is BOTH an actor and itself reportable — Apple
  # 1.2 and Google Play UGC both require reporting and blocking *users*, not just
  # content (docs/compliance.md). So including Actor also includes
  # Moderate::Reportable, giving a user the reportable contract with sensible
  # actor-flavored defaults (a user IS its own `reported_owner`).
  #
  # Everything host-specific (what "banned" means, whether a block tears down a
  # pending invite) is delegated to the configured hooks via the Moderate facade,
  # never hard-coded here — keeping the actor host-agnostic.
  module Actor
    extend ActiveSupport::Concern

    # A user is also reportable. Pulling Reportable in here means `participates_in_moderation`
    # alone gives you both halves (act AND be-acted-on) without a second macro.
    include Moderate::Reportable

    included do
      # Blocks this actor initiated, and blocks filed against this actor. Two
      # associations on the one Moderate::Block table, distinguished by which
      # foreign key points here. `dependent: :destroy` cleans up the edges if the
      # account is hard-deleted (a soft-delete/ban leaves them, which is correct —
      # the safety edge should outlive a suspension).
      has_many :moderate_initiated_blocks,
        class_name: "Moderate::Block",
        foreign_key: :blocker_id,
        inverse_of: :blocker,
        dependent: :destroy
      has_many :moderate_received_blocks,
        class_name: "Moderate::Block",
        foreign_key: :blocked_id,
        inverse_of: :blocked,
        dependent: :destroy

      # Reports this actor filed, and reports filed against this actor. `nullify`
      # (not destroy): a report is legal/evidentiary and must survive either party
      # deleting their account — we just detach the foreign key. `moderate_reports`
      # is the README-documented reader for "reports against me / my content."
      has_many :moderate_submitted_reports,
        class_name: "Moderate::Report",
        foreign_key: :reporter_id,
        inverse_of: :reporter,
        dependent: :nullify
      has_many :moderate_reports,
        class_name: "Moderate::Report",
        foreign_key: :reported_user_id,
        inverse_of: :reported_user,
        dependent: :nullify
    end

    # --- Reporting ------------------------------------------------------------

    # File a report from this actor against a piece of content (or another actor —
    # a user with `participates_in_moderation` is itself reportable).
    #
    #   current_user.report!(@message, category: :harassment, details: "...")
    #   current_user.report!(@other_user, category: :impersonation)
    #
    # We build and persist a Moderate::Report; the Report model owns the rest of
    # the lifecycle the README promises — snapshotting the offending content so
    # evidence survives edits/deletes, inferring the responsible owner, sending the
    # reporter a receipt, and dropping it into the queue. Keeping that logic IN the
    # model (not here) means the public DSA notice intake and this in-app path share
    # one source of truth.
    #
    # `details:` is the README's name for the reporter's free-text reason; it maps
    # onto the Report's `message`. Extra keyword args (e.g. `field:`) pass straight
    # through, so this stays forward-compatible with the Report model's attributes.
    def report!(reportable, category:, details: nil, **attributes)
      attributes[:message] = details if details && !attributes.key?(:message)
      reported_field = attributes.delete(:reported_field) || attributes.delete(:field)

      # An in-app reporter attests to good faith IMPLICITLY by choosing to report —
      # there's no separate checkbox in the in-app flow (that's the public DSA notice
      # form's job). The Report model requires `good_faith_confirmed` to be truthy
      # (Art. 16(2)(d)), so we set it here for the community path unless the caller
      # already passed it. (A host that wants an explicit in-app attestation can still
      # override by passing `good_faith_confirmed:` in `attributes`.)
      attributes[:good_faith_confirmed] = true unless attributes.key?(:good_faith_confirmed)

      report = Moderate::Report.new(
        reporter: self,
        reportable: reportable,
        category: category.to_s,
        intake_kind: "community",
        **attributes
      )

      intake = Moderate::Services::IntakeReport.new(
        report: report,
        reporter: self,
        reportable: reportable,
        reported_field: reported_field
      )
      return report if intake.save

      raise ActiveRecord::RecordInvalid, report
    end

    # --- Blocking -------------------------------------------------------------
    #
    # Blocking is a BIDIRECTIONAL safety edge: once either side blocks, neither
    # should see or reach the other. The single source of truth for "who can't see
    # whom" is `Moderate.blocked_ids_for`, which reads BOTH directions — so these
    # predicates expose each direction, and `blocked_with?` is the one you check in
    # features.

    # Block `other` (idempotent, audited, fires the `on_block` hook). The actual
    # create/audit/notify is owned by Moderate::Block.block! so there's one block
    # write path for the whole gem.
    def block!(other)
      Moderate::Block.block!(blocker: self, blocked: other)
    end

    # Lift a block this actor placed on `other`. No-op (returns false) if no such
    # block exists.
    def unblock!(other)
      Moderate::Block.unblock!(blocker: self, blocked: other)
    end

    # Did I block them? (one direction)
    def blocks?(other)
      return false if other.blank?

      moderate_initiated_blocks.exists?(blocked_id: other.id)
    end

    # Did they block me? (the other direction)
    def blocked_by?(other)
      return false if other.blank?

      moderate_received_blocks.exists?(blocker_id: other.id)
    end

    # Is there a block edge in EITHER direction? This is the predicate to check in
    # product code ("can these two interact?") — blocking is symmetric for
    # visibility/reachability even though only one side pressed the button. A
    # self-check is never "blocked."
    def blocked_with?(other)
      return false if other.blank? || other.id == id

      blocks?(other) || blocked_by?(other)
    end

    # --- Reportable defaults for an actor -------------------------------------
    #
    # A user is reportable; these override Moderate::Reportable's defaults with
    # actor-appropriate behavior. Hosts can override again for richer copy/rules.

    # A user is responsible for themselves — so a report against a user (e.g. for
    # impersonation) attributes to and notifies that same user.
    def reported_owner
      self
    end

    # You can never report yourself, and a field still has to be reportable. This
    # tightens Reportable's default with the self-report guard, so the
    # `moderate_report_link` helper hides the control on your own profile.
    def report_visible_to?(viewer, field:)
      viewer.present? && viewer.id != id && reportable_field_allowed?(field)
    end
  end
end
