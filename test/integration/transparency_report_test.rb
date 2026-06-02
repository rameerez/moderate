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
end
