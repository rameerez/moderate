# frozen_string_literal: true

module Moderate
  # View helpers exposed to BOTH the engine's own views and the HOST app's views.
  #
  # The headline helper is `moderate_report_link` (and its terser alias
  # `report_link`): a one-liner you drop next to any reportable piece of content to
  # render an in-app "Report" affordance — the exact thing Apple Guideline 1.2 and
  # Google Play's UGC policy require every social/UGC app to surface next to
  # user-generated content.
  #   - https://developer.apple.com/app-store/review/guidelines/#user-generated-content
  #   - https://support.google.com/googleplay/android-developer/answer/9876937
  #
  # GOTCHA — isolated engine + host views: `Moderate::Engine` is an *isolated*
  # engine (`isolate_namespace Moderate`). Rails does NOT auto-include an isolated
  # engine's helpers into the host application's views — that's the whole point of
  # isolation. But `moderate_report_link` is meant to be called from the host's own
  # templates (e.g. `<%= moderate_report_link(@comment, field: :body) %>`), so we
  # explicitly mix this module into ActionView for the host at load time via the
  # `ActiveSupport.on_load(:action_view)` hook at the bottom of this file. That is
  # the same trick Devise uses to expose its url helpers app-wide.
  module EngineHelper
    # Render an in-app report affordance for `record`'s `field`, or NOTHING when the
    # current viewer isn't allowed to report it.
    #
    # Renders nothing (returns nil) — deliberately, and in three cases:
    #   1. there is no signed-in viewer (anonymous users use the public DSA notice
    #      form instead; this is the *in-app* button), or
    #   2. the record doesn't know how to be reported (no `report_visible_to?`), or
    #   3. the record says this viewer may not report this field
    #      (`record.report_visible_to?(viewer, field:)` is false — e.g. you can't
    #      report your own content, or content you can't even see).
    #
    # This "render nothing unless permitted" contract is what lets a host sprinkle
    # the helper liberally across a template without guarding each call site — the
    # helper is the guard. It mirrors the reference app's `report_link`.
    #
    # @param record  [Object] any model that `include`s Moderate::Reportable
    # @param field   [Symbol, String, nil] which field is being reported (nil =>
    #   the whole record). Passed straight through to the visibility check and the
    #   intake form so the moderator sees exactly which field was flagged.
    # @param label   [String, nil] the visible link text. Defaults to a translated
    #   "Report" string so the host gets i18n for free.
    # @param html_options [Hash] extra HTML attributes merged onto the <a> (class,
    #   data-*, aria-*, …) so the host can style it to taste without a wrapper.
    # @return [ActiveSupport::SafeBuffer, nil]
    def moderate_report_link(record, field: nil, label: nil, **html_options)
      viewer = moderate_current_viewer
      return if viewer.nil?

      # The record gates its own reportability. We `respond_to?`-guard so a host can
      # pass any object without the helper exploding — a non-reportable object simply
      # renders nothing, same as "not permitted".
      return unless record.respond_to?(:report_visible_to?)
      return unless record.report_visible_to?(viewer, field: field)

      label ||= moderate_report_default_label
      link_to(label, moderate_report_path_for(record, field: field), **html_options)
    end

    # Terse alias. The README/docs use `moderate_report_link` in host views (to
    # avoid clashing with a host's own `report_link`), but `report_link` reads
    # cleanest inside the engine's own templates. Same method, two names.
    def report_link(record, field: nil, label: nil, **html_options)
      moderate_report_link(record, field: field, label: label, **html_options)
    end

    private

    # The path to the in-app intake form for this record/field.
    #
    # The target is passed as a SIGNED Global ID, never a raw `type`+`id`. This is
    # the load-bearing security decision of the report flow: a raw polymorphic
    # `reportable_type`/`reportable_id` pair in a URL is attacker-controlled — anyone
    # could file a report against an arbitrary record (or probe which ids exist).
    # A signed GID is tamper-proof and scoped to a single purpose, so the intake
    # controller can `locate_signed_reportable` it back to the exact record the host
    # chose to expose here, and nothing else.
    # See: https://api.rubyonrails.org/classes/GlobalID/Identification.html#method-i-to_sgid
    #
    # NOTE: the in-app report controller/route is the host's (BYOUI) — `moderate`
    # ships the primitives, not the in-app report UI. So we build the path from the
    # host's named route (`new_report_path`/`new_moderate_report_path`) when present
    # and fall back to a conventional `/reports/new?target=…` otherwise, rather than
    # hard-coding the engine's routes (which only cover the *public* DSA form).
    def moderate_report_path_for(record, field:)
      target = moderate_signed_target(record)
      query = { target: target, field: field.presence }.compact

      if respond_to?(:new_report_path)
        new_report_path(query)
      elsif respond_to?(:new_moderate_report_path)
        new_moderate_report_path(query)
      else
        # Last-resort conventional path so the helper is never a hard dependency on
        # a particular route name. The host wires the actual route (BYOUI).
        "/reports/new?#{query.to_query}"
      end
    end

    # The record as a signed, purpose-scoped GID parameter. We delegate to the
    # Reportable concern's own signer when available (so the purpose/expiry stay in
    # ONE place — the model), and fall back to `to_sgid_param` with the canonical
    # purpose otherwise.
    def moderate_signed_target(record)
      return record.to_moderation_sgid if record.respond_to?(:to_moderation_sgid)

      # GlobalID's signed param, scoped to a stable purpose string so a token minted
      # for reporting can't be replayed against an unrelated signed-GID feature.
      #
      # `expires_in: nil` mints a NON-EXPIRING token on purpose. By default
      # `to_sgid_param` bakes in an `exp` timestamp (SignedGlobalID.expires_in, ~1
      # month), which makes the token — and therefore the rendered link's URL —
      # CHANGE on every render. That breaks HTTP/fragment caching of pages that show
      # the report link, and makes the link non-deterministic. The token is already
      # purpose-scoped ("moderate_report") and the locator restricts resolution to the
      # allow-listed reportable classes, so a stable, non-expiring identifier is the
      # right trade-off here: it identifies WHICH record to report, it doesn't grant
      # any capability that needs to time out.
      record.to_sgid_param(for: "moderate_report", expires_in: nil)
    end

    # Who is viewing — resolved without coupling `moderate` to any auth gem. We try
    # `current_user` (Devise/most apps) first; a host with a different actor accessor
    # can override `moderate_current_viewer` in their own helper. nil => anonymous,
    # which correctly hides the in-app button.
    def moderate_current_viewer
      return current_user if respond_to?(:current_user)

      nil
    end

    # Default link text, pulled through I18n so it localizes with the host's locale
    # and can be overridden without touching call sites. Falls back to plain English
    # if the host hasn't loaded the gem's locale file.
    def moderate_report_default_label
      if defined?(I18n)
        I18n.t("moderate.report_link.label", default: "Report")
      else
        "Report"
      end
    end
  end
end

# Expose the helper to the HOST app's views (see the "isolated engine" gotcha in
# the module doc above). `on_load(:action_view)` defers until ActionView is loaded,
# so we never force it at boot and we play nice with the host's load order.
ActiveSupport.on_load(:action_view) do
  include Moderate::EngineHelper
end if defined?(ActiveSupport)
