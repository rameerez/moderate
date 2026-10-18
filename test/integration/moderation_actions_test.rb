# frozen_string_literal: true

require "test_helper"

# Moderate::Moderation, the drop-in admin decision actions, driven over HTTP the way
# a host's admin (madmin or hand-rolled) uses them: one `resolve`/`dismiss` pair for
# BOTH queues (reports and flags), `uphold`/`reject` for appeals. The dummy's
# Admin::*Controller include the concern and nothing else (test/dummy/app/controllers/admin).
class ModerationActionsTest < ActionDispatch::IntegrationTest
  setup do
    Moderate.configure do |config|
      config.audit = ->(event) { ModerateTestRecorder.audit(event) }
      config.notify = ->(event) { ModerateTestRecorder.notify(event) }
      config.ban_handler = ModerateTestRecorder.method(:ban_handler)
    end
    ModerateTestRecorder.clear
    @moderator = User.create!(name: "Mod", email: "mod@example.com")
    @author = User.create!(name: "Author", email: "author@example.com")
    @reporter = User.create!(name: "Reporter", email: "reporter@example.com")
    @comment = Comment.create!(user: @author, body: "something rude")
  end

  test "resolve decides a report, with a 303 back" do
    report = @reporter.report!(@comment, category: :harassment, details: "Rude", field: :body)

    post "/admin/reports/#{report.id}/resolve",
      params: { moderator_id: @moderator.id, note: "Warned.", ban_user: "1", resolution_basis: "terms" }

    assert_response :see_other
    assert_equal "Report resolved.", flash[:notice]
    assert_equal "actioned", report.reload.status
    assert_equal @moderator, report.resolved_by
    assert_equal [@author], ModerateTestRecorder.bans.pluck(:user)
  end

  test "resolve decides a flag too, and can enforce through a report" do
    flag = flag_on(@comment)

    post "/admin/flags/#{flag.id}/resolve", params: { moderator_id: @moderator.id, note: "Abusive.", ban_user: "1" }

    assert_response :see_other
    assert_equal "Flag actioned.", flash[:notice]
    assert_equal "actioned", flag.reload.status
    assert_equal @moderator, flag.reviewed_by
    assert_equal "actioned", flag.report.status
    assert_equal [@author], ModerateTestRecorder.bans.pluck(:user)
  end

  test "resolve on a flag with no enforcement only triages it" do
    flag = flag_on(@comment)

    post "/admin/flags/#{flag.id}/resolve", params: { moderator_id: @moderator.id, note: "Seen." }

    assert_equal "actioned", flag.reload.status
    assert_nil flag.report
    assert_empty ModerateTestRecorder.bans
  end

  test "dismiss closes a flag" do
    flag = flag_on(@comment)

    post "/admin/flags/#{flag.id}/dismiss", params: { moderator_id: @moderator.id, note: "False positive." }

    assert_equal "Flag dismissed.", flash[:notice]
    assert_equal "dismissed", flag.reload.status
  end

  test "a missing note comes back as an alert, and nothing changes" do
    flag = flag_on(@comment)

    post "/admin/flags/#{flag.id}/resolve", params: { moderator_id: @moderator.id, note: "", ban_user: "1" }

    assert_response :see_other
    assert_match(/Could not resolve/, flash[:alert])
    assert_predicate flag.reload, :pending?
    assert_empty ModerateTestRecorder.bans
  end

  private

  def flag_on(record)
    Moderate::Flag.flag!(
      flaggable: record, field: "body", owner: @author, source: "text_filter", mode: "flag",
      excerpt: record.body, categories: ["harassment"], scores: {}, context: {}
    )
  end
end
