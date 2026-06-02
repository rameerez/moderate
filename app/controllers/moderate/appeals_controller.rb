# frozen_string_literal: true

module Moderate
  # Public DSA Art. 20 internal complaint form for moderation decisions.
  class AppealsController < Moderate::ApplicationController
    helper_method :turnstile_widget_required?

    before_action :enforce_appeal_enabled!
    before_action :throttle_appeals!, only: :create
    before_action :verify_human!, only: :create

    def new
      @report = Moderate::Report.locate_signed_appeal_report(params[:token])
      return redirect_to appeal_return_path, alert: t("moderate.appeals.not_found", default: "We couldn't find that moderation decision.") if @report.blank?

      @appeal = Moderate::Appeal.new(
        report: @report,
        appellant: current_appellant,
        appellant_name: current_appellant_name,
        appellant_email: current_appellant_email,
        source: appeal_source_for(@report, params[:source])
      )
    end

    def create
      @report = Moderate::Report.locate_signed_appeal_report(params[:token])
      return redirect_to appeal_return_path, alert: t("moderate.appeals.not_found", default: "We couldn't find that moderation decision.") if @report.blank?

      attributes = appeal_params
      attributes[:source] = appeal_source_for(@report, attributes[:source])

      intake = Moderate::Services::IntakeAppeal.new(
        appeal: Moderate::Appeal.new(attributes),
        report: @report,
        appellant: current_appellant
      )
      @appeal = intake.appeal

      if intake.save
        redirect_to appeal_return_path,
          notice: t("moderate.appeals.received", default: "Appeal received. A human reviewer will assess the decision."),
          status: :see_other
      else
        render :new, status: :unprocessable_entity
      end
    end

    private

    def appeal_params
      params.require(:appeal).permit(:appellant_name, :appellant_email, :source, :reason)
    end

    def appeal_source_for(report, requested_source)
      return "affected_user" if current_appellant.present? && current_appellant.id == report.reported_user_id

      source = requested_source.to_s.squish
      return "notifier" if source == "affected_user" && report.reported_user_id.blank?

      Moderate::Appeal::SOURCES.include?(source) ? source : "notifier"
    end

    def current_appellant
      return @current_appellant if defined?(@current_appellant)

      @current_appellant =
        if respond_to?(:current_user, true)
          current_user
        end
    rescue StandardError
      @current_appellant = nil
    end

    def current_appellant_name
      current_appellant&.try(:display_name) || current_appellant&.try(:name)
    end

    def current_appellant_email
      current_appellant&.try(:email)
    end

    def appeal_return_path
      path = Moderate.config.appeal_return_path
      path = path.call(self) if path.respond_to?(:call)
      path.presence || "/"
    end

    def enforce_appeal_enabled!
      return if Moderate.config.appeal_form_enabled

      raise ActionController::RoutingError, "Moderate appeal form is disabled (config.appeal_form_enabled = false)"
    end

    def throttle_appeals!
      limit = Moderate.config.appeal_rate_limit
      return if limit == false || limit.nil?

      max = limit.fetch(:max, 10)
      within = limit.fetch(:within, 60).to_i

      key = "moderate:appeal_rate:#{request.remote_ip}"
      count = rate_limit_increment(key, expires_in: within)

      render_rate_limited if count > max
    end

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
      flash.now[:alert] = t("moderate.appeals.rate_limited", default: "Too many appeals from this address. Please try again later.")
      rebuild_appeal_from_params
      render :new, status: :too_many_requests
    end

    def verify_human!
      return if human_verification_skipped?

      if turnstile_available?
        verify_turnstile!
      else
        run_appeal_guard!
      end
    end

    def turnstile_widget_required?
      turnstile_available? && !human_verification_skipped?
    end

    def human_verification_skipped?
      predicate = Moderate.config.appeal_human_verification_skip_if
      return false unless predicate.respond_to?(:call)

      predicate.call(self) ? true : false
    rescue StandardError
      false
    end

    def turnstile_available?
      defined?(::RailsCloudflareTurnstile) && respond_to?(:validate_cloudflare_turnstile, true)
    end

    def verify_turnstile!
      validate_cloudflare_turnstile
    rescue ::RailsCloudflareTurnstile::Forbidden
      render_captcha_failed
    end

    def run_appeal_guard!
      guard = Moderate.config.appeal_guard
      return unless guard.respond_to?(:call)
      return if safe_call_guard(guard)

      render_captcha_failed
    end

    def safe_call_guard(guard)
      guard.call(self) ? true : false
    rescue StandardError
      false
    end

    def render_captcha_failed
      flash.now[:alert] = t("moderate.appeals.captcha_failed", default: "We couldn't verify you're human. Please try the check again.")
      rebuild_appeal_from_params
      render :new, status: :unprocessable_entity
    end

    def rebuild_appeal_from_params
      @report ||= Moderate::Report.locate_signed_appeal_report(params[:token])
      @appeal = Moderate::Appeal.new(appeal_params_safe)
      @appeal.report = @report if @report
      @appeal.source = appeal_source_for(@report, @appeal.source) if @report
    end

    def appeal_params_safe
      appeal_params.to_h
    rescue ActionController::ParameterMissing
      {}
    end
  end
end
