# frozen_string_literal: true

module Moderate
  # Public aggregate transparency report for moderation intake, decisions, appeals,
  # and automated flags.
  class TransparencyReportsController < Moderate::ApplicationController
    before_action :ensure_transparency_report_enabled!

    def show
      @period_start = 1.year.ago.beginning_of_day
      @period_end = Time.current
      # The aggregation is a public facade method so a host that keeps this page off
      # (it's opt-in) can still call `Moderate.transparency(from:, to:)` to publish
      # its own report. The view renders the same hash either way.
      @summary = Moderate.transparency(from: @period_start, to: @period_end)
    end

    private

    # Hard kill-switch: the public transparency report is OFF unless the host opts
    # in with `config.transparency_report_enabled = true`. Raising RoutingError makes
    # the mounted route behave as if it doesn't exist (a 404), same pattern as the
    # notice/appeal form kill-switches.
    def ensure_transparency_report_enabled!
      return if Moderate.config.transparency_report_enabled

      raise ActionController::RoutingError, "Moderate transparency report is disabled (config.transparency_report_enabled = false)"
    end
  end
end
