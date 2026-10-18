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

    assert_equal(counts_of(reports: 1), counts)
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
      assert_equal(counts_of(reports: 1, appeals: 1), Moderate.purge)
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

    assert_equal(counts_of(reports: 1), Moderate.purge(dry_run: true))
    assert_equal "They insulted me", report.reload.message
    assert_empty ModerateTestRecorder.audits_named(:retention_purged)

    Moderate.purge
    assert_equal(counts_of, Moderate.purge)
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

  # --- Content can't fake being done (redacted_at, not the text, decides) -----

  test "a report, flag and appeal whose text literally reads [redacted] are still purged, and dry_run counts them" do
    report = decided_report(at: 2.years.ago, details: Moderate::Retention::REDACTED)
    appeal = travel_to(2.years.ago + 1.day) do
      Moderate::Appeal.create!(report: report, appellant: @reporter, reason: Moderate::Retention::REDACTED)
    end
    travel_to(2.years.ago + 2.days) { appeal.reject!(by: @moderator, note: "Stands") }
    flag = Moderate::Flag.flag_for_review!(Comment.create!(user: @author, body: "x"), field: :body, by: @moderator)
    flag.update_columns(excerpt: Moderate::Retention::REDACTED)
    travel_to(2.years.ago) { flag.dismiss!(by: @moderator, note: "Fine") }

    assert_equal(counts_of(reports: 1, flags: 1, appeals: 1), Moderate.purge(dry_run: true))
    Moderate.purge

    report.reload
    assert_not_nil report.redacted_at
    assert_nil report.reporter_id, "the reporter goes even though the message already read [redacted]"
    assert_equal ["redacted_at"], report.snapshot.keys
    assert_not_nil flag.reload.redacted_at
    assert_equal ["redacted_at"], flag.context.keys
    assert_nil appeal.reload.appellant_email
    assert_not_nil appeal.redacted_at
    assert_equal(counts_of, Moderate.purge)
  end

  # --- Legal holds ------------------------------------------------------------

  test "a held report, its appeals and the flags on its content are kept; dry_run lists them as held" do
    report = decided_report(at: 2.years.ago)
    appeal = travel_to(2.years.ago + 1.day) do
      Moderate::Appeal.create!(report: report, appellant: @reporter, reason: "Please look again")
    end
    travel_to(2.years.ago + 2.days) { appeal.reject!(by: @moderator, note: "Stands") }
    flag = Moderate::Flag.flag_for_review!(@comment, field: :body, by: @moderator)
    travel_to(2.years.ago) { flag.dismiss!(by: @moderator, note: "Fine") }
    other = decided_report(at: 2.years.ago)
    other.update_columns(reportable_id: nil, reportable_type: nil) # about something else

    Moderate.hold(report, until: 6.months.from_now, by: @moderator, reason: "ODS case 114")

    assert_predicate report.reload, :held?
    assert_equal(counts_of(reports: 1, held: { reports: 1, flags: 1, appeals: 1 }), Moderate.purge(dry_run: true))
    assert_equal(counts_of(reports: 1, held: { reports: 1, flags: 1, appeals: 1 }), Moderate.purge)
    assert_equal "They insulted me", report.reload.message
    assert_equal "Please look again", appeal.reload.reason
    assert_nil flag.reload.redacted_at
    assert_not_nil other.reload.redacted_at

    placed = ModerateTestRecorder.audits_named(:legal_hold_placed).first
    assert_equal "ODS case 114", placed.payload[:reason]
    assert_equal @moderator, placed.actor
  end

  test "a hold expires on its own, and release_hold lifts it now" do
    report = decided_report(at: 2.years.ago)
    Moderate.hold(report, until: 1.month.from_now)

    travel_to(2.months.from_now) { assert_equal 1, Moderate.purge(dry_run: true)[:reports], "an expired hold keeps nothing" }

    Moderate.release_hold(report, by: @moderator)
    assert_nil report.reload.held_until
    assert_equal 1, Moderate.purge[:reports]
    assert_equal 1, ModerateTestRecorder.audits_named(:legal_hold_released).size
  end

  test "a hold needs a time in the future" do
    report = decided_report(at: 2.years.ago)

    assert_raises(ArgumentError) { Moderate.hold(report, until: 1.day.ago) }
    assert_raises(ArgumentError) { Moderate.hold(report, until: nil) }
  end

  test "classification rows older than the period are deleted, recent ones kept" do
    old = travel_to(2.years.ago) { Moderate::Classification.create!(record: @comment, field: "photo", digest: "a" * 16, classified_at: Time.current) }
    recent = Moderate::Classification.create!(record: @comment, field: "photo", digest: "b" * 16, classified_at: Time.current)

    assert_equal 1, Moderate.purge(dry_run: true)[:classifications]
    assert_equal 1, Moderate.purge[:classifications]

    assert_not Moderate::Classification.exists?(old.id)
    assert Moderate::Classification.exists?(recent.id)
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
    assert_match "kept for a legal hold: 0 reports, 0 flags, 0 appeals", output
    assert_equal "They insulted me", report.reload.message

    output = with_env("OLDER_THAN_DAYS" => "365", "DRY_RUN" => nil) { run_purge_task }
    assert_match "redacted 1 reports", output
    assert_equal Moderate::Retention::REDACTED, report.reload.message
  end

  private

  def counts_of(reports: 0, flags: 0, appeals: 0, classifications: 0, held: {})
    { reports: reports, flags: flags, appeals: appeals, classifications: classifications,
      held: { reports: 0, flags: 0, appeals: 0 }.merge(held) }
  end

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
