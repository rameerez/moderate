# frozen_string_literal: true

require "test_helper"

# DSA Art. 20(2): the (at least) six-month appeal window starts on the day the person
# is informed of the decision. The decision sets a minimum (decision + 6 months);
# only a CONFIRMED delivery (Moderate.delivered!, from the mailer's delivery) moves
# it later, once, and nothing moves it earlier.
class Moderate::AppealWindowTest < ActiveSupport::TestCase
  setup do
    Moderate.configure do |config|
      config.ban_handler = ->(user:, by:, reason:) { ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason) }
      # A notifier that QUEUES the mail and returns its job: truthy, not delivered.
      config.notify = ->(event) { ModerateTestRecorder.notify(event) && :delivery_job }
    end
    @reporter = User.create!(name: "Reporter", email: "reporter@example.com")
    @author = User.create!(name: "Author", email: "author@example.com")
    @moderator = User.create!(name: "Mod", email: "mod@example.com")
    @comment = Comment.create!(user: @author, body: "a rude comment")
    @report = @reporter.report!(@comment, category: :harassment, field: :body, details: "Insult")
    @decided_at = Time.current
    @service = Moderate::Services::ResolveReport.new(@report, by: @moderator)
    @service.resolve!(note: "Harassment", ban_user: true)
    @report.reload
  end

  def file_appeal(at:)
    appeal = Moderate::Appeal.new(report: @report, appellant: @author, reason: "Please look again", source: "affected_user")
    travel_to(at) { appeal.save }
    appeal
  end

  def window_from(time) = (time + Moderate::Report::APPEAL_WINDOW).to_f

  test "a notice that was only queued leaves the clock at decision + six months, and says so" do
    assert_nil @report.affected_user_notified_at
    assert_in_delta window_from(@decided_at), @report.appeal_deadline_at.to_f, 5

    statement = ModerateTestRecorder.notifications_named(:affected_user_decision).last
    assert_in_delta window_from(@decided_at), statement.payload[:appeal_deadline_at].to_f, 5,
      "the notice states the minimum it can promise"
  end

  test "a confirmed delivery two months late extends the window, once" do
    delivered_at = @decided_at + 2.months
    Moderate.delivered!(@report, :affected_user, at: delivered_at)

    @report.reload
    assert_in_delta delivered_at.to_f, @report.affected_user_notified_at.to_f, 1
    assert_in_delta window_from(delivered_at), @report.appeal_deadline_at.to_f, 1

    Moderate.delivered!(@report, :affected_user, at: delivered_at + 1.month)
    assert_in_delta window_from(delivered_at), @report.reload.appeal_deadline_at.to_f, 1, "a second confirmation changes nothing"
    assert_in_delta delivered_at.to_f, @report.affected_user_notified_at.to_f, 1
  end

  test "re-running deliver_decision_notices does not move the clock" do
    Moderate.delivered!(@report, :affected_user, at: @decided_at + 1.month)
    deadline = @report.reload.appeal_deadline_at

    travel_to(@decided_at + 3.months) { @service.deliver_decision_notices }

    assert_equal deadline, @report.reload.appeal_deadline_at
  end

  test "late filing is measured from the confirmed delivery" do
    Moderate.delivered!(@report, :affected_user, at: @decided_at + 2.months)

    assert_predicate file_appeal(at: @decided_at + 7.months), :persisted?
    too_late = file_appeal(at: @decided_at + 9.months)
    assert_not_predicate too_late, :persisted?
    assert_includes too_late.errors[:report].join, "appeal window"
  end

  test "without a confirmation, a seven-month appeal is late" do
    assert_not_predicate file_appeal(at: @decided_at + 7.months), :persisted?
  end

  test "a delivery never moves the deadline earlier, and needs a decided report and a known notice" do
    later = 1.year.from_now
    @report.update_column(:appeal_deadline_at, later)
    Moderate.delivered!(@report, :decision)
    assert_in_delta later.to_f, @report.reload.appeal_deadline_at.to_f, 1

    assert_raises(ArgumentError) { Moderate.delivered!(@report, :someone) }

    open_report = @reporter.report!(Comment.create!(user: @author, body: "x"), category: :spam, field: :body)
    Moderate.delivered!(open_report, :decision)
    assert_nil open_report.reload.decision_notified_at, "nothing was decided, so nothing was delivered"
  end
end
