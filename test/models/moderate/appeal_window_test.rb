# frozen_string_literal: true

require "test_helper"

# DSA Art. 20(2): the (at least) six-month appeal window starts on the day the person
# is informed of the decision. A decision notice delivered late moves the deadline;
# one that never goes out leaves the decision-time deadline.
class Moderate::AppealWindowTest < ActiveSupport::TestCase
  setup do
    Moderate.configure do |config|
      config.ban_handler = ->(user:, by:, reason:) { ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason) }
    end
    @reporter = User.create!(name: "Reporter", email: "reporter@example.com")
    @author = User.create!(name: "Author", email: "author@example.com")
    @moderator = User.create!(name: "Mod", email: "mod@example.com")
    @comment = Comment.create!(user: @author, body: "a rude comment")
    @report = @reporter.report!(@comment, category: :harassment, field: :body, details: "Insult")
  end

  def deliver_notices
    Moderate.config.notify = ->(event) { ModerateTestRecorder.notify(event) }
  end

  def decide_now_notify_later(delay)
    service = Moderate::Services::ResolveReport.new(@report, by: @moderator, deliver: false)
    service.resolve!(note: "Harassment", ban_user: true)
    travel_to(Time.current + delay) { service.deliver_decision_notices } # in UTC, not across local DST
    @report.reload
  end

  def file_appeal(at:, appellant: @author)
    travel_to(at) { Moderate::Appeal.new(report: @report, appellant: appellant, reason: "Please look again", source: "affected_user") }
      .tap { |appeal| travel_to(at) { appeal.save } }
  end

  test "a statement of reasons delivered two months late extends the window to six months after it" do
    deliver_notices
    decided_at = Time.current
    decide_now_notify_later(2.months)

    assert_in_delta (decided_at + 2.months + Moderate::Report::APPEAL_WINDOW).to_f, @report.appeal_deadline_at.to_f, 5
    assert_in_delta (decided_at + 2.months).to_f, @report.affected_user_notified_at.to_f, 5

    statement = ModerateTestRecorder.notifications_named(:affected_user_decision).last
    assert_in_delta @report.appeal_deadline_at.to_f, statement.payload[:appeal_deadline_at].to_f, 5,
      "the notice states the deadline that its own delivery sets"
  end

  test "an appeal filed seven months after the decision, five after the late notice, is in time" do
    deliver_notices
    decided_at = Time.current
    decide_now_notify_later(2.months)

    appeal = file_appeal(at: decided_at + 7.months)
    assert_predicate appeal, :persisted?, appeal.errors.full_messages.to_sentence

    too_late = file_appeal(at: decided_at + 9.months)
    assert_not_predicate too_late, :persisted?
    assert_includes too_late.errors[:report].join, "appeal window"
  end

  test "with no notifier the window runs from the decision, and a seven-month appeal is late" do
    decided_at = Time.current
    decide_now_notify_later(2.months) # the default notify hook delivers nothing

    assert_nil @report.affected_user_notified_at
    assert_in_delta (decided_at + Moderate::Report::APPEAL_WINDOW).to_f, @report.appeal_deadline_at.to_f, 5
    assert_not_predicate file_appeal(at: decided_at + 7.months), :persisted?
  end

  test "a delivery never moves the deadline earlier" do
    deliver_notices
    @report.resolve!(by: @moderator, note: "Harassment", ban_user: true)
    later = 1.year.from_now
    @report.reload.update_column(:appeal_deadline_at, later)

    @report.record_notified!(:decision_notified_at)

    assert_in_delta later.to_f, @report.reload.appeal_deadline_at.to_f, 1
  end
end
