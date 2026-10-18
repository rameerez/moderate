# frozen_string_literal: true

require "test_helper"
require "rake"

# Moderate.purge / Moderate::Retention: opt-in redaction of personal data in final
# moderation records, keeping every row and its decision (docs/compliance.md#retention).
class Moderate::RetentionTest < ActiveSupport::TestCase
  setup do
    Moderate.configure do |config|
      config.audit = ->(event) { ModerateTestRecorder.audit(event) }
    end
    ModerateTestRecorder.clear

    @reporter = User.create!(name: "Reporter", email: "reporter@example.com")
    @author = User.create!(name: "Author", email: "author@example.com")
    @moderator = User.create!(name: "Mod", email: "mod@example.com")
    @comment = Comment.create!(user: @author, body: "a rude comment")
  end

  def decided_report(at:, **attributes)
    report = travel_to(at - 1.day) do
      @reporter.report!(@comment, category: :harassment, field: :body, details: "They insulted me", **attributes)
    end
    travel_to(at) { report.dismiss!(by: @moderator, note: "No violation") }
    report.reload
  end

  def dsa_notice
    Moderate::Report.create!(
      intake_kind: "dsa", category: "illegal_content", legal_reason: "public_security",
      legal_country_code: "ES", content_type: "listing", subject_url: "https://example.test/c/1", message: "Illegal threat",
      notifier_name: "Ana Notifier", notifier_email: "ana@example.com", good_faith_confirmed: true
    )
  end

  test "nothing is purged unless the host calls it: records keep everything by default" do
    report = decided_report(at: 3.years.ago)

    assert_equal "They insulted me", report.message
    assert_equal "a rude comment", report.snapshot["content_text"]
  end

  test "a final report older than the cutoff loses its personal data and keeps its decision" do
    report = decided_report(at: 2.years.ago)

    counts = Moderate.purge(older_than: 1.year)

    assert_equal({ reports: 1, flags: 0, appeals: 0 }, counts)
    report.reload
    assert_equal Moderate::Retention::REDACTED, report.message
    assert_nil report.reporter_id
    assert_equal ["redacted_at"], report.snapshot.keys
    # The decision and what it was about stay: statement of reasons, transparency.
    assert_equal "dismissed", report.status
    assert_equal "No violation", report.resolution_note
    assert_equal "harassment", report.category
    assert_equal @author.id, report.reported_user_id
    assert_equal "body", report.reported_field
    assert_not_nil report.resolved_at
  end

  test "a DSA notice loses the notifier's name, email and URLs" do
    notice = dsa_notice
    travel_to(2.years.ago) { notice.dismiss!(by: @moderator, note: "Not illegal") }

    Moderate.purge

    notice.reload
    assert_nil notice.notifier_name
    assert_nil notice.notifier_email
    assert_nil notice.subject_url
    assert_equal [], notice.subject_urls
    assert_equal "public_security", notice.legal_reason
    assert_equal "ES", notice.legal_country_code
  end

  test "recent, pending and still-appealable reports are kept as they are" do
    recent = decided_report(at: 2.months.ago)
    pending = travel_to(3.years.ago) { @reporter.report!(@comment, category: :spam, field: :body, details: "Spam") }
    appealable = decided_report(at: 2.years.ago)
    appealable.update_column(:appeal_deadline_at, 1.week.from_now)

    assert_equal 0, Moderate.purge(older_than: 1.year)[:reports]

    assert_equal "They insulted me", recent.reload.message
    assert_equal "Spam", pending.reload.message
    assert_equal "They insulted me", appealable.reload.message
  end

  test "a report with an open appeal keeps its evidence until the appeal is decided" do
    report = travel_to(1.month.ago) do
      r = @reporter.report!(@comment, category: :harassment, field: :body, details: "Insult")
      r.dismiss!(by: @moderator, note: "No violation")
      r
    end
    appeal = Moderate::Appeal.create!(report: report, appellant: @reporter, reason: "Please look again.")
    travel_to(2.years.from_now) do
      assert_equal 0, Moderate.purge[:reports], "an open appeal holds its report"

      appeal.reject!(by: @moderator, note: "Decision stands")
    end

    travel_to(4.years.from_now) do
      assert_equal({ reports: 1, flags: 0, appeals: 1 }, Moderate.purge)
    end
    assert_equal Moderate::Retention::REDACTED, appeal.reload.reason
    assert_nil appeal.appellant_email
    assert_equal "rejected", appeal.status
    assert_equal "Decision stands", appeal.resolution_note
  end

  test "a decided flag loses its excerpt and context; a pending flag is kept" do
    decided = Moderate::Flag.flag_for_review!(@comment, field: :body, by: @moderator, note: "Look at this")
    travel_to(2.years.ago) { decided.dismiss!(by: @moderator, note: "Fine") }
    other = Comment.create!(user: @author, body: "another")
    pending = travel_to(3.years.ago) { Moderate::Flag.flag_for_review!(other, field: :body, by: @moderator) }

    assert_equal 1, Moderate.purge[:flags]

    decided.reload
    assert_equal Moderate::Retention::REDACTED, decided.excerpt
    assert_equal ["redacted_at"], decided.context.keys
    assert_equal "dismissed", decided.status
    assert_equal "manual", decided.source
    assert_equal "another", pending.reload.excerpt
  end

  test "dry_run counts without changing anything, and a second run finds nothing to do" do
    report = decided_report(at: 2.years.ago)

    assert_equal({ reports: 1, flags: 0, appeals: 0 }, Moderate.purge(dry_run: true))
    assert_equal "They insulted me", report.reload.message
    assert_empty ModerateTestRecorder.audits_named(:retention_purged)

    Moderate.purge
    assert_equal({ reports: 0, flags: 0, appeals: 0 }, Moderate.purge)
    audits = ModerateTestRecorder.audits_named(:retention_purged)
    assert_equal 1, audits.size, "only a run that changed something is audited"
    assert_equal 1, audits.first.payload[:reports]
  end

  test "transparency counts are the same before and after a purge" do
    decided_report(at: 2.years.ago)
    notice = dsa_notice
    travel_to(2.years.ago) { notice.dismiss!(by: @moderator, note: "Not illegal") }
    period = { from: 10.years.ago, to: Time.current }
    before = Moderate.transparency(**period).except(:period)

    Moderate.purge

    assert_equal before, Moderate.transparency(**period).except(:period)
  end

  test "older_than may not be shorter than the appeal window" do
    error = assert_raises(ArgumentError) { Moderate.purge(older_than: 3.months) }
    assert_match "appeal window", error.message
    assert_raises(ArgumentError) { Moderate.purge(older_than: nil) }
  end

  test "blocks are never touched" do
    @reporter.block!(@author)
    travel_to(10.years.from_now) { Moderate.purge }

    assert @reporter.blocks?(@author)
  end

  test "the moderate:purge rake task purges, and DRY_RUN only counts" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "moderate:purge" }
    report = decided_report(at: 2.years.ago)

    output = with_env("OLDER_THAN_DAYS" => "365", "DRY_RUN" => "1") { run_purge_task }
    assert_match "would redact 1 reports", output
    assert_equal "They insulted me", report.reload.message

    output = with_env("OLDER_THAN_DAYS" => "365", "DRY_RUN" => nil) { run_purge_task }
    assert_match "redacted 1 reports", output
    assert_equal Moderate::Retention::REDACTED, report.reload.message
  end

  private

  def run_purge_task
    task = Rake::Task["moderate:purge"]
    task.reenable
    capture_io { task.invoke }.first
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
