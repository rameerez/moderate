# frozen_string_literal: true

require "test_helper"

class TransparencyReportTest < ActionDispatch::IntegrationTest
  test "public transparency report renders aggregate moderation counters" do
    # The public report is opt-in (off by default — see config.transparency_report_enabled).
    Moderate.config.transparency_report_enabled = true

    Moderate::Report.create!(
      notifier_name: "Notice Sender",
      notifier_email: "notice@example.com",
      category: "illegal_content",
      intake_kind: "dsa",
      legal_reason: "public_security",
      legal_country_code: "ES",
      content_type: "listing",
      subject_url: "https://example.test/content/1",
      message: "Please review",
      good_faith_confirmed: true
    )

    get "/trust/transparency"

    assert_response :success
    assert_includes response.body, "Moderation transparency"
    assert_includes response.body, "Public security"
  end

  test "Moderate.transparency aggregates the period counters and is queryable even when the page is OFF" do
    Moderate.config.transparency_report_enabled = false # the page is disabled…

    Moderate::Report.create!(
      notifier_name: "Notice Sender",
      notifier_email: "notice@example.com",
      category: "illegal_content",
      intake_kind: "dsa",
      legal_reason: "public_security",
      legal_country_code: "ES",
      content_type: "listing",
      subject_url: "https://example.test/content/2",
      message: "Please review",
      good_faith_confirmed: true
    )

    # …but the aggregation a host needs to publish its own report still works.
    summary = Moderate.transparency(from: 1.day.ago, to: Time.current)
    assert_equal({ "dsa" => 1 }, summary[:notices_by_intake])
    assert_equal({ "public_security" => 1 }, summary[:dsa_notices_by_legal_reason])
    assert summary.key?(:median_notice_action_seconds)
    assert summary.key?(:appeals_by_status)
  end
end
