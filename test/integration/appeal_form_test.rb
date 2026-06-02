# frozen_string_literal: true

require "test_helper"

class AppealFormTest < ActionDispatch::IntegrationTest
  NEW = "/trust/appeals/new"
  CREATE = "/trust/appeals"

  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false

    Moderate.configure do |config|
      config.audit = ->(event) { ModerateTestRecorder.audit(event) }
      config.notify = ->(event) { ModerateTestRecorder.notify(event) }
      config.appeal_rate_limit = false
      config.appeal_return_path = "/"
    end
    ModerateTestRecorder.clear
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
  end

  test "GET new renders an appeal form for a signed moderation decision" do
    report = closed_report(reported_user: User.create!(name: "Affected", email: "affected@example.com"))
    token = report.signed_appeal_gid

    get NEW, params: { token: token, source: "affected_user" }

    assert_response :success
    assert_select "form[action=?]", "#{CREATE}?token=#{CGI.escape(token)}"
    assert_select "input[name=?][value=?]", "appeal[source]", "affected_user"
  end

  test "POST create saves, notifies, audits, and redirects to the configured return path" do
    report = closed_report
    token = report.signed_appeal_gid

    assert_difference -> { Moderate::Appeal.count }, 1 do
      post CREATE, params: {
        token: token,
        appeal: {
          appellant_name: "Appealing Person",
          appellant_email: "appeal@example.com",
          source: "notifier",
          reason: "Please review this decision."
        }
      }
    end

    assert_redirected_to "/"
    appeal = Moderate::Appeal.last
    assert_equal report, appeal.report
    assert_equal "notifier", appeal.source
    assert_equal 1, ModerateTestRecorder.notifications_named(:appeal_received).size
    assert_equal 1, ModerateTestRecorder.audits_named(:appeal_received).size
  end

  test "affected_user source falls back to notifier when the report has no affected user" do
    report = closed_report

    post CREATE, params: {
      token: report.signed_appeal_gid,
      appeal: {
        appellant_name: "Appealing Person",
        appellant_email: "appeal@example.com",
        source: "affected_user",
        reason: "Please review this decision."
      }
    }

    assert_equal "notifier", Moderate::Appeal.last.source
  end

  test "a configured appeal guard can block create" do
    Moderate.config.appeal_guard = ->(_controller) { false }
    report = closed_report

    assert_no_difference -> { Moderate::Appeal.count } do
      post CREATE, params: {
        token: report.signed_appeal_gid,
        appeal: {
          appellant_name: "Appealing Person",
          appellant_email: "appeal@example.com",
          source: "notifier",
          reason: "Please review this decision."
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/verify/i, flash[:alert].to_s)
  end

  test "a configured human verification skip bypasses the appeal browser guard" do
    Moderate.config.appeal_guard = ->(_controller) { false }
    Moderate.config.appeal_human_verification_skip_if = ->(controller) {
      controller.request.user_agent.to_s.include?("Hotwire Native")
    }
    report = closed_report

    assert_difference -> { Moderate::Appeal.count }, 1 do
      post CREATE,
        params: {
          token: report.signed_appeal_gid,
          appeal: {
            appellant_name: "Appealing Person",
            appellant_email: "appeal@example.com",
            source: "notifier",
            reason: "Please review this decision."
          }
        },
        headers: { "User-Agent" => "Hotwire Native iOS" }
    end

    assert_redirected_to "/"
  end

  private

  def closed_report(reported_user: nil)
    Moderate::Report.create!(
      reported_user: reported_user,
      notifier_name: "Notice Sender",
      notifier_email: "notice@example.com",
      category: "illegal_content",
      subject_url: "https://example.test/content/1",
      message: "Please review",
      good_faith_confirmed: true,
      status: "dismissed",
      resolution_note: "No violation",
      resolution_basis: "no_violation",
      decision_visibility: "no_restriction",
      resolved_at: Time.current,
      appeal_deadline_at: 1.month.from_now
    )
  end
end
