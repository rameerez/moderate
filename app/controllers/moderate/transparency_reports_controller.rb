# frozen_string_literal: true

module Moderate
  # Public aggregate transparency report for moderation intake, decisions, appeals,
  # and automated flags.
  class TransparencyReportsController < Moderate::ApplicationController
    before_action :ensure_transparency_report_enabled!

    def show
      @period_start = 1.year.ago.beginning_of_day
      @period_end = Time.current
      reports = Moderate::Report.where(created_at: @period_start..@period_end)
      appeals = Moderate::Appeal.where(created_at: @period_start..@period_end)
      flags = Moderate::Flag.where(created_at: @period_start..@period_end)

      @summary = {
        notices_by_intake: reports.group(:intake_kind).count,
        dsa_notices_by_legal_reason: reports.where(intake_kind: "dsa").group(:legal_reason).count,
        actions_by_basis: reports.where.not(resolved_at: nil).group(:resolution_basis).count,
        automated_flags_by_source: flags.group(:source).count,
        appeals_by_status: appeals.group(:status).count,
        median_notice_action_seconds: median_seconds(reports.where.not(resolved_at: nil).pluck(:created_at, :resolved_at)),
        median_appeal_action_seconds: median_seconds(appeals.where.not(resolved_at: nil).pluck(:created_at, :resolved_at))
      }
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

    def median_seconds(pairs)
      values = pairs.filter_map { |created_at, resolved_at| resolved_at && created_at ? (resolved_at - created_at).to_i : nil }.sort
      return 0 if values.empty?

      values[values.length / 2]
    end
  end
end
