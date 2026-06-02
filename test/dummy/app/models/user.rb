# frozen_string_literal: true

# The dummy host's ACTOR model — the `config.user_class`.
#
# `participates_in_moderation` (the macro the engine adds to ActiveRecord::Base) makes a User
# able to report, block/unblock, be reported, and be banned; because Actor pulls in
# Reportable, a User is ALSO reportable (Apple 1.2 / Google Play UGC both require
# reporting AND blocking *users*, not just content). `reportable :name` narrows the
# reportable surface to a single field so the suite can exercise the field
# whitelist (a report naming `:name` is allowed; one naming an undeclared field is
# rejected by Moderate::Report's reportable_field_must_be_allowed validation).
class User < ApplicationRecord
  participates_in_moderation
  reportable :name

  # The initializer declares `config.filter "User", :name, mode: :flag`, so a User
  # is also a Moderate::ContentFilterable target on `:name`. We include the concern
  # explicitly (rather than via the `moderates` macro) so the model still loads if a
  # test resets config and re-declares the policy — the concern just needs to know
  # WHICH fields to run on commit; the per-field adapter/mode comes from config.
  include Moderate::ContentFilterable
  moderates_fields :name

  # `email` / `display_name` are read by Moderate::Report#hydrate_reporter_contact
  # via `try`, so they're optional — but providing real columns lets the suite
  # assert the notifier identity is copied off the reporter. `display_name` falls
  # back to the name column for a friendlier label.
  def display_name
    self[:display_name].presence || name
  end
end
