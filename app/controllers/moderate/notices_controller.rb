# frozen_string_literal: true

module Moderate
  # The PUBLIC, regulator-facing DSA "notice and action" intake form.
  #
  # The EU Digital Services Act, Article 16, requires every hosting service serving
  # EU users to offer a PUBLIC, ELECTRONIC mechanism for ANYONE (not just logged-in
  # users) to flag illegal content, and to ACKNOWLEDGE receipt of that notice. This
  # controller is that mechanism — the "Report illegal content (EU)" form you see at
  # the bottom of X / YouTube / Reddit. It is separate from the in-app "Report"
  # button (that's the host's BYOUI report controller) and from the admin queue.
  # See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj  (Article 16)
  #
  # The controller is intentionally boring: it does HTTP only. All the Trust &
  # Safety work — the Art. 16 field validations, the immutable evidence snapshot,
  # the durable acknowledgement (Art. 16(4)), dropping the row into
  # `Moderate::Report.pending`, and firing the `notice_received` confirmation-of-
  # receipt event — lives in the model/service (`Moderate::Services::IntakeNotice`
  # building a `Moderate::Report` with `intake_kind: "dsa"`), never here.
  #
  # A notice is NOT a fourth table: it is a `Moderate::Report` with
  # `intake_kind: "dsa"`, sharing the same queue, snapshot, appeal window, and Art.
  # 24 transparency counters as an in-app report. One queue, two front doors.
  class NoticesController < Moderate::ApplicationController
    # Hard kill-switch: if a host sets `config.notice_form_enabled = false`, the
    # whole engine surface 404s. Lets an app mount the engine but disable the form
    # (e.g. it doesn't serve EU users) without un-mounting routes.
    before_action :enforce_notice_enabled!

    # Anti-abuse, defense-in-depth, applied only to the state-changing POST. Both
    # gates degrade to "off" gracefully so the form is never a support burden in
    # environments that don't need them (dev/test, or apps that gate at the edge).
    before_action :throttle_notices!, only: :create

    # The bot gate, auto-wired. A single before_action that decides AT REQUEST TIME
    # which check to run, so the wiring auto-adapts to whether the host has the
    # `rails_cloudflare_turnstile` gem — no hard dependency, no class-reload to flip
    # the behavior. See #verify_human! near the bottom of this file for the branch.
    before_action :verify_human!, only: :create

    # GET /notices/new — the form, prefilled (and partially locked) from the request.
    #
    # X-style deep link: a host can link to this form from a piece of content with
    # the reported-content details already in the query string (content_url,
    # content_type, content_author, content_id — see #prefill_attributes), so the
    # notifier doesn't have to copy-paste the URL of what they're flagging. We ALSO
    # prefill the notifier's identity from Devise `current_user` when someone happens
    # to be logged in (the form is still public/anonymous-friendly). The view locks
    # the auto-prefilled IDENTITY fields so they can't be tampered with, while the
    # reported-content fields stay fully editable. DSA Art. 16(2)(b)/(c).
    def new
      @report = Moderate::Report.new(prefill_attributes)
      @identity_locked = identity_locked?
    end

    # POST /notices — validate + persist as a DSA-kind Report, fire the confirmation
    # of receipt, and show the submitter a success page. On failure we re-render the
    # form with the model's validation errors and a 422 (standard Rails; lets Turbo
    # replace the form in place).
    def create
      @intake = Moderate::Services::IntakeNotice.new(
        attributes: notice_params,
        reporter: current_notifier
      )

      if @intake.save
        redirect_to(
          new_notice_path,
          notice: t("moderate.notices.received", default: "Notice received. We have logged your report and will review it."),
          status: :see_other
        )
      else
        @report = @intake.report
        @identity_locked = identity_locked?
        render :new, status: :unprocessable_entity
      end
    end

    private

    # --- Prefill (Art. 16(2)(b)/(c)) ------------------------------------------

    # The attributes used to PREFILL the blank form. Two sources, deliberately kept
    # apart so the view can lock one and leave the other editable:
    #   * REPORTED-CONTENT fields, from the query string (an X-style deep link). These
    #     stay EDITABLE — the notifier is allowed to correct the URL or pick a
    #     different content type.
    #   * IDENTITY fields, from Devise `current_user`. These are LOCKED by the view
    #     (readonly/disabled) so a logged-in notifier can't spoof someone else's
    #     name/email onto a legal notice.
    def prefill_attributes
      content_prefill.merge(identity_prefill)
    end

    # Reported-content prefill from the query string. The param NAMES are the gem's
    # documented contract (docs/dsa-notice-form.md), chosen to read naturally in a
    # link and to map cleanly onto the Report's Art. 16 columns:
    #   content_url    → subject_url    ("the exact electronic location", Art. 16(2)(b))
    #   content_type   → content_type   (constrained to Report::CONTENT_TYPES; we only
    #                                     prefill a value the model will accept, so a
    #                                     junk query param can't pre-poison the select)
    #   content_author → reported_account_identifier (a host-side handle/username, free text)
    #   content_id     → reported_account_identifier fallback if no author was given
    # All are OPTIONAL: a bare /notices/new with no query string renders a blank form.
    def content_prefill
      type = params[:content_type].to_s
      {
        subject_url: params[:content_url].presence,
        # Only echo a content_type the model's inclusion validation would accept, so
        # a crafted ?content_type=<script> can never reach the page as a selected value.
        content_type: (type.presence if Moderate::Report::CONTENT_TYPES.include?(type)),
        reported_account_identifier: params[:content_author].presence || params[:content_id].presence
      }.compact
    end

    # Identity prefill from the signed-in user, when one exists. We detect Devise (or
    # any auth that exposes `current_user`) WITHOUT a hard dependency: the engine's
    # base controller may or may not define `current_user` depending on the host's
    # `notice_parent_controller`. `respond_to?` keeps the public/anonymous form
    # working when nobody is logged in (the overwhelmingly common case for Art. 16).
    # We read name/email via `try` so the host's user class only needs whichever it
    # actually has. These keys are what the view LOCKS.
    def identity_prefill
      user = current_notifier
      return {} if user.nil?

      {
        notifier_name: user.try(:display_name) || user.try(:name),
        notifier_email: user.try(:email)
      }.compact
    end

    # Whether the IDENTITY fields are locked (readonly) on the form. They are locked
    # exactly when there's a signed-in user whose identity we prefilled — so an
    # anonymous notice keeps name/email editable, and a logged-in notice locks them
    # against tampering. Passed to the view as `@identity_locked` so the view never
    # has to reach for `current_user` itself (it isn't exposed as a view helper here).
    def identity_locked?
      user = current_notifier
      return false if user.nil?

      (user.try(:email) || user.try(:display_name) || user.try(:name)).present?
    end

    # The logged-in submitter, if any — read defensively. The form is PUBLIC: most
    # notices come from anonymous notifiers, so `current_notifier` is usually nil and
    # the notice is a name+email-only record (not tied to a User). We only call
    # `current_user` when the parent controller actually defines it (Devise-style),
    # so the engine never hard-depends on an auth gem. `defined?` guards the symbol
    # itself for parents that expose it as a helper_method but not a public method.
    def current_notifier
      return @current_notifier if defined?(@current_notifier)

      @current_notifier =
        if respond_to?(:current_user, true)
          current_user
        end
    rescue StandardError
      # A host `current_user` that raises (e.g. a not-yet-migrated session) must not
      # break the public notice form — fall back to "anonymous".
      @current_notifier = nil
    end

    # --- Strong params --------------------------------------------------------

    # Strong params — the Art. 16 field set mapped onto the Report columns. These are
    # the fields the regulation dictates (legal ground, exact URL, substantiated
    # explanation, notifier identity, member state, good-faith attestation, plus the
    # content-type bucket the snapshot needs); there's no product decision to make,
    # so the permit list is fixed.
    #
    # SECURITY NOTE — the LOCKED identity fields. The view renders the prefilled
    # `notifier_name`/`notifier_email` as readonly/disabled for a logged-in notifier;
    # a *disabled* field is NOT submitted by the browser, so on create we re-derive
    # identity from `current_user` and OVERWRITE whatever the params carried. That way
    # a tampered request that re-enables the field and posts a forged name can't land
    # a spoofed identity on a legal notice. For an anonymous notifier (no
    # current_user) the posted name/email are used as-is — they're the only identity
    # there is.
    def notice_params
      permitted = params.require(:notice).permit(
        :legal_reason,                 # DSA statement-of-reasons taxonomy (Art. 17 ground)
        :legal_country_code,           # ISO-3166 EU/EEA selector — jurisdiction/routing
        :content_type,                 # host-agnostic CONTENT_TYPES bucket for the snapshot
        :subject_url,                  # "the exact electronic location" — Art. 16(2)(b)
        :message,                      # "sufficiently substantiated explanation" — Art. 16(2)(a)
        :reported_account_identifier,  # optional host-side handle the notice is about
        :notifier_name,                # Art. 16(2)(c)
        :notifier_email,               # Art. 16(2)(c) — where the confirmation + decision go
        :good_faith_confirmed,         # Art. 16(2)(d) attestation — must be checked
        :anonymous                     # the narrow Art. 16(2)(c) minors carve-out
      )

      enforce_locked_identity(permitted)
    end

    # Re-assert the locked identity from the signed-in user, ignoring whatever the
    # client posted for name/email. No-op for anonymous notifiers. See the security
    # note on #notice_params.
    def enforce_locked_identity(permitted)
      user = current_notifier
      return permitted if user.nil?

      name = user.try(:display_name) || user.try(:name)
      email = user.try(:email)
      permitted[:notifier_name] = name if name.present?
      permitted[:notifier_email] = email if email.present?
      permitted
    end

    # 404 the form when the host has disabled it.
    def enforce_notice_enabled!
      return if Moderate.config.notice_form_enabled

      raise ActionController::RoutingError, "Moderate notice form is disabled (config.notice_form_enabled = false)"
    end

    # --- Rate limit (per-IP throttle) ----------------------------------------

    # A public, unauthenticated POST is a spam/abuse magnet, so we throttle per IP.
    #
    # Rails 7.2 shipped a first-class controller `rate_limit` macro; on 7.1 it
    # doesn't exist, so we fall back to a tiny `Rails.cache`-backed counter. We
    # implement the throttle as a single `before_action` (rather than the class-level
    # `rate_limit` macro) precisely so we can honor the host's RUNTIME
    # `config.notice_rate_limit` (the macro is evaluated at class load, before the
    # host's initializer has necessarily run).
    # https://api.rubyonrails.org/classes/ActionController/RateLimiting/ClassMethods.html
    def throttle_notices!
      limit = Moderate.config.notice_rate_limit
      return if limit == false || limit.nil? # explicitly disabled

      max = limit.fetch(:max, 5)
      within = limit.fetch(:within, 3600).to_i # seconds; the config stores a raw Integer

      key = "moderate:notice_rate:#{request.remote_ip}"
      count = rate_limit_increment(key, expires_in: within)

      render_rate_limited if count > max
    end

    # Increment a per-IP counter in the cache, setting the TTL on first write so the
    # window slides correctly. We guard against a missing cache store (NullStore in a
    # bare test env) by treating "can't count" as "not limited" — the form must never
    # break just because rate-limiting can't run.
    def rate_limit_increment(key, expires_in:)
      store = Rails.cache
      return 0 unless store

      current = store.read(key).to_i
      store.write(key, current + 1, expires_in: expires_in) if current.zero?
      store.increment(key) || (current + 1)
    rescue StandardError
      0
    end

    def render_rate_limited
      flash.now[:alert] = t(
        "moderate.notices.rate_limited",
        default: "Too many notices from this address. Please try again later."
      )
      @report ||= Moderate::Report.new(prefill_attributes)
      @identity_locked = identity_locked?
      render :new, status: :too_many_requests
    end

    # --- Bot gate (auto-integrates rails_cloudflare_turnstile when present) -----

    # The single, request-time bot gate. Layered so a host gets the right behavior
    # with zero wiring:
    #
    #   1. If the `rails_cloudflare_turnstile` gem is installed, run ITS server-side
    #      check — the gem auto-includes RailsCloudflareTurnstile::ControllerHelpers
    #      into every controller (via its railtie's on_load(:action_controller)
    #      hook), so `validate_cloudflare_turnstile` is an instance method here. That
    #      method is exactly what the gem's README tells a host to put in a
    #      before_action; we call it automatically so the host wires NOTHING beyond
    #      installing the gem + its keys. A failed challenge raises
    #      RailsCloudflareTurnstile::Forbidden, which we catch and turn into a
    #      friendly 422 (the submitter retries the check) rather than a raw error.
    #      https://github.com/instrumentl/rails-cloudflare-turnstile (README)
    #
    #   2. Otherwise, fall back to the host-configurable `config.notice_guard` proc
    #      (no-op by default, so the form just works in dev/test and for apps that
    #      gate at the edge). The proc receives THIS controller and returns a boolean
    #      (truthy ⇒ allowed). A host on hCaptcha / reCAPTCHA / their own check wires
    #      it; a host on Cloudflare Turnstile installs the gem and gets path (1) free.
    #
    # Detection is via `defined?`/`respond_to?` with NO hard dependency in the
    # gemspec, decided at REQUEST time so the wiring auto-adapts to the bundle.
    def verify_human!
      if turnstile_available?
        verify_turnstile!
      else
        run_notice_guard!
      end
    end

    # True when the gem is loaded AND its controller helper is mixed in here, so a
    # half-loaded/renamed gem can never put us on a path whose method doesn't exist.
    def turnstile_available?
      defined?(::RailsCloudflareTurnstile) && respond_to?(:validate_cloudflare_turnstile, true)
    end

    # Run the gem's verifier, translating its `Forbidden` into our friendly 422. We
    # reference the exception class by `defined?`-guarded constant so this file never
    # hard-names a constant that may not exist (the gem is optional).
    def verify_turnstile!
      validate_cloudflare_turnstile
    rescue ::RailsCloudflareTurnstile::Forbidden
      render_captcha_failed
    end

    # The gem-absent fallback gate (see #verify_human! point 2). We read the guard
    # via `respond_to?` so the form still works on a Configuration that predates the
    # `notice_guard` accessor (treated as "no guard" ⇒ the form just works).
    def run_notice_guard!
      return unless Moderate.config.respond_to?(:notice_guard)

      guard = Moderate.config.notice_guard
      return unless guard.respond_to?(:call)
      return if truthy?(safe_call_guard(guard))

      render_captcha_failed
    end

    # Never let a flaky/broken guard raise into the request — a bot service must not
    # 500 a legal notice form. An exception is treated as "failed closed" (we can't
    # prove the human), which re-renders the form so the submitter can retry.
    def safe_call_guard(guard)
      guard.call(self)
    rescue StandardError
      false
    end

    # Shared failure renderer for BOTH gate paths (a failed Turnstile challenge and a
    # falsy/raising guard). Re-renders `new` with a friendly 422 so the submitter can
    # try the check again. We rebuild a prefilled (and re-locked) report so the form
    # comes back populated rather than blank.
    def render_captcha_failed
      flash.now[:alert] = t(
        "moderate.notices.captcha_failed",
        default: "We couldn't verify you're human. Please try the check again."
      )
      @report ||= Moderate::Report.new(prefill_attributes.merge(notice_params_safe))
      @identity_locked = identity_locked?
      render :new, status: :unprocessable_entity
    end

    # Like `notice_params` but as a plain SYMBOL-keyed Hash and tolerant of a missing
    # `notice` key, so re-rendering after a failed gate (where params may be partial)
    # never raises — and so it merges cleanly over the symbol-keyed `prefill_attributes`
    # (a string-keyed Parameters would create duplicate logical keys and not override).
    def notice_params_safe
      notice_params.to_h.symbolize_keys
    rescue ActionController::ParameterMissing
      {}
    end

    def truthy?(value)
      value ? true : false
    end
  end
end
