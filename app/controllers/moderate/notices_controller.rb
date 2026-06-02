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
  # Safety work — Art. 16 field validations, the evidence snapshot, the opaque
  # `reference`, dropping the row into `Moderate::Report.pending`, and firing the
  # `notice_received` confirmation-of-receipt event (Art. 16(4)) — lives in the
  # model/service (`Moderate::IntakeNotice` / `Moderate::Notice`), not here.
  class NoticesController < Moderate::ApplicationController
    # Hard kill-switch: if a host sets `config.notice_form_enabled = false`, the
    # whole engine surface 404s. Lets an app mount the engine but disable the form
    # (e.g. it doesn't serve EU users) without un-mounting routes.
    before_action :enforce_notice_enabled!

    # Anti-abuse, defense-in-depth, applied only to the state-changing POST. Both
    # gates degrade to "off" gracefully so the form is never a support burden in
    # environments that don't need them (dev/test, or apps that gate at the edge).
    before_action :throttle_notices!, only: :create
    before_action :verify_turnstile!, only: :create

    # GET /notices/new — the blank form.
    def new
      @notice = Moderate::Notice.new
    end

    # GET /notices/:id — the public receipt, looked up by the OPAQUE `reference`
    # (e.g. "DSA-7Q2K-9F3X"), never by sequential `id`. Looking up by id would let
    # anyone enumerate other people's notices; the reference is unguessable and is
    # the value shown on the receipt and emailed to the notifier.
    def show
      @notice = Moderate::Notice.find_by!(reference: params[:id])
    end

    # POST /notices — validate + persist, fire the confirmation-of-receipt, redirect
    # to the receipt. On failure, re-render the form with the model's validation
    # errors and a 422 (standard Rails; lets Turbo replace the form in place).
    def create
      @notice = Moderate::Notice.new(notice_params)

      if intake.save
        redirect_to(
          notice_path(@notice.reference),
          notice: t("moderate.notices.received", default: "Notice received. We have logged your report and will review it."),
          status: :see_other
        )
      else
        render :new, status: :unprocessable_entity
      end
    end

    private

    # The intake service owns the side effects of a successful submission (the
    # snapshot, the audit record, the `notice_received` event). We memoize the
    # instance built around `@notice` so `create` reads as one decision. If the host
    # build doesn't define the service yet, we degrade to the model's own `save`,
    # which the docs guarantee does the same Art. 16 work — the controller never
    # hard-depends on the service class existing.
    def intake
      @intake ||=
        if defined?(Moderate::IntakeNotice)
          Moderate::IntakeNotice.new(@notice, request: request)
        else
          ModelSaveAdapter.new(@notice)
        end
    end

    # Thin shim so `intake.save` is the single call site whether we're using the
    # service or the bare model. Keeps `create` identical in both branches.
    class ModelSaveAdapter
      def initialize(record) = @record = record
      def save = @record.save
    end
    private_constant :ModelSaveAdapter

    # Strong params — EXACTLY the Art. 16 field set, no more. These are the fields
    # the regulation dictates (legal reason, exact URL, substantiated explanation,
    # notifier identity, member state, good-faith attestation); there's no product
    # decision to make, so the permit list is fixed. The model maps these doc-named
    # attributes onto its columns and validates each one.
    def notice_params
      params.require(:notice).permit(
        :legal_reason,    # DSA statement-of-reasons taxonomy (Art. 17 ground)
        :content_url,     # "the exact electronic location" — Art. 16(2)(b)
        :explanation,     # "sufficiently substantiated explanation" — Art. 16(2)(a)
        :notifier_name,   # Art. 16(2)(c)
        :notifier_email,  # Art. 16(2)(c) — where the confirmation + decision go
        :member_state,    # ISO-3166 EU/EEA selector — jurisdiction/routing
        :good_faith       # Art. 16(2)(d) attestation — must be checked
      )
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
    # `rate_limit` macro) precisely so we can branch on the Rails version AND honor
    # the host's runtime `config.notice_rate_limit` (the macro is evaluated at class
    # load, before the host's initializer has necessarily run).
    # https://api.rubyonrails.org/classes/ActionController/RateLimiting/ClassMethods.html
    def throttle_notices!
      limit = Moderate.config.notice_rate_limit
      return if limit == false || limit.nil? # explicitly disabled

      max = limit.fetch(:max, 5)
      within = limit.fetch(:within, 3600) # seconds; the config stores a raw Integer
      within = within.to_i

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
      @notice ||= Moderate::Notice.new
      render :new, status: :too_many_requests
    end

    # --- Bot gate (Cloudflare Turnstile, pluggable) --------------------------

    # Verify the human-check on submit. The gate is layered:
    #   1. A host-supplied `config.notice_captcha_verifier` lambda wins outright,
    #      so a host on hCaptcha / reCAPTCHA / their own check is never locked into
    #      Turnstile. The lambda gets the controller and returns a boolean.
    #   2. Otherwise, if a Turnstile secret IS configured, verify the token
    #      server-side against Cloudflare's siteverify endpoint.
    #   3. Otherwise (no verifier, no secret), the gate NO-OPS — the form just works
    #      (dev/test, or apps that gate at the edge).
    # On failure we re-render the form 422 with a friendly error, so the submitter
    # can retry. We never let the verifier raise into the request — a flaky bot
    # service must not 500 a legal notice form; an exception is treated as "failed
    # closed" only for the explicit verifier path, and "skip" for our optional
    # built-in path (see below).
    def verify_turnstile!
      verifier = Moderate.config.notice_captcha_verifier
      if verifier.respond_to?(:call)
        return if truthy?(safe_call_verifier(verifier))

        return render_captcha_failed
      end

      secret = Moderate.config.notice_turnstile_secret_key
      return if secret.to_s.strip.empty? # unconfigured => gate is off

      return if turnstile_token_valid?(secret)

      render_captcha_failed
    end

    def safe_call_verifier(verifier)
      verifier.call(self)
    rescue StandardError
      false # a broken custom verifier fails closed (we can't prove the human)
    end

    # Server-side Turnstile verification. POSTs the response token to Cloudflare's
    # siteverify. We keep the HTTP here minimal and stdlib-only (`net/http`) so the
    # gem adds no dependency for an optional feature. A network error fails OPEN
    # (returns true): a Cloudflare outage should not block legitimate EU legal
    # notices — the rate-limit and audit trail remain as backstops, and silently
    # dropping Art. 16 notices is the worse compliance outcome.
    # https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
    def turnstile_token_valid?(secret)
      token = params["cf-turnstile-response"].to_s
      return false if token.empty?

      require "net/http"
      require "uri"
      require "json"

      uri = URI("https://challenges.cloudflare.com/turnstile/v0/siteverify")
      response = Net::HTTP.post_form(uri, secret: secret, response: token, remoteip: request.remote_ip)
      body = JSON.parse(response.body)
      body["success"] == true
    rescue StandardError
      true # fail open on infra errors — see method doc
    end

    def render_captcha_failed
      flash.now[:alert] = t(
        "moderate.notices.captcha_failed",
        default: "We couldn't verify you're human. Please try the check again."
      )
      @notice ||= Moderate::Notice.new(notice_params_safe)
      render :new, status: :unprocessable_entity
    end

    # Like `notice_params` but tolerant of a missing `notice` key (so re-rendering
    # after a failed gate, where params may be partial, never raises).
    def notice_params_safe
      notice_params
    rescue ActionController::ParameterMissing
      {}
    end

    def truthy?(value)
      value ? true : false
    end
  end
end
