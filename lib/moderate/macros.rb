# frozen_string_literal: true

# The macros lazily mix the gem's concerns into a host model.
#
# We DON'T `require_relative` the concern files here, even though this file is
# itself require_relative'd by the spine (lib/moderate.rb) at gem-load time. The
# concerns (Moderate::Actor / Reportable / ContentFilterable) live under
# `lib/moderate/models/concerns/` and are AUTOLOADED by Zeitwerk (the engine
# `push_dir`s that subtree under the `Moderate` namespace with the `models` and
# `concerns` dirs collapsed). Requiring them here too would double-manage the same
# constants and make Zeitwerk raise on its eager-load pass ("already defined").
#
# This is safe because the macro methods below only REFERENCE the concern constants
# inside their bodies (`include Moderate::Actor`), which run when a host model calls
# `has_moderation`/`reportable`/`moderates` — long after boot, when the autoloader
# is fully wired. So Zeitwerk autoloads each concern lazily on first use.
module Moderate
  # The class-level DSL the gem adds to every ActiveRecord model.
  #
  # The engine does `ActiveSupport.on_load(:active_record) { extend Moderate::Macros }`,
  # so `has_moderation`, `reportable`, and `moderates` become class methods on
  # ActiveRecord::Base — readable plain-English declarations that sit alongside the
  # rest of a host's stack (`has_credits`, `has_wallets`, `has_api_keys`):
  #
  #   class User    < ApplicationRecord; has_moderation; end
  #   class Listing < ApplicationRecord; reportable :title, :description; end
  #   class Message < ApplicationRecord; moderates :body, mode: :flag; end
  #
  # Each macro is exact sugar for an `include` + a declaration — the README
  # documents both forms as equivalent. The macros are deliberately thin: they
  # lazily include the right concern (only models that opt in pay for it) and then
  # forward to that concern's declaration method. All behavior lives in the
  # concerns, never here.
  module Macros
    # `has_moderation` — make this model an ACTOR (and, since a user is itself
    # reportable, a reportable too): report!/block!/unblock!/blocks?/blocked_with?,
    # the block & report associations, and the be-banned target.
    #
    # Equivalent to `include Moderate::Actor`. Idempotent: re-declaring (or both
    # macro + explicit include) won't double-include.
    def has_moderation
      include Moderate::Actor unless include?(Moderate::Actor)
    end

    # `reportable(*fields)` — make this content reportable, optionally narrowing to
    # specific fields. Bare `reportable` (no fields) means "the whole record is
    # reportable" (the field whitelist stays empty, and a blank reported_field is
    # then allowed — see Reportable#reportable_field_allowed?).
    #
    # Equivalent to `include Moderate::Reportable` + `reportable_fields(*fields)`.
    def reportable(*fields)
      include Moderate::Reportable unless include?(Moderate::Reportable)
      reportable_fields(*fields) if fields.any?
      self
    end

    # `moderates(*fields, mode:, with:)` — filter one or more fields before they're
    # saved. `mode:`/`with:` default to nil so the field inherits the global
    # `config.default_filter_mode` / `config.filter_adapter` (resolved inside
    # `config.filter`), letting a bare `moderates :body` Just Work.
    #
    # Two things happen, per field:
    #   1. The field is registered on the model (Moderate::ContentFilterable), so
    #      the :block validation and :flag after_commit hook run for it.
    #   2. A Configuration FilterPolicy is recorded keyed by [class_name, field],
    #      so `Moderate.filter_policy_for` (which the concern consults at
    #      validate/commit time, walking the ancestor chain) can find the field's
    #      adapter + mode. This is the exact twin of `config.filter "Class", :field,
    #      with:, mode:` in the initializer — same storage, same resolution.
    #
    # Equivalent to `include Moderate::ContentFilterable` + `moderates_fields(*fields)`
    # plus the per-field policy registration.
    def moderates(*fields, mode: nil, with: nil)
      include Moderate::ContentFilterable unless include?(Moderate::ContentFilterable)
      moderates_fields(*fields)

      fields.each do |field|
        # `config.filter` normalizes/validates the adapter+mode and stores the
        # policy; passing `self` (the class) lets it record the class NAME string.
        Moderate.config.filter(self, field, with: with, mode: mode)
      end

      self
    end
  end
end
