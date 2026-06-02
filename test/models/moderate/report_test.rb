# frozen_string_literal: true

require "test_helper"

module Moderate
  # Tests for Moderate::Report — the core notice/report record (in-app community
  # report AND public DSA legal notice, distinguished by `intake_kind`).
  #
  # Ported from test/models/moderation/report_test.rb and fully de-host-ified: the
  # reference's marketplace listings are replaced by the dummy Comment (a reportable
  # piece of content) and the dummy User (itself reportable). Assertions track the
  # GEM's columns and behavior — the immutable snapshot, the inferred reported_user,
  # the signed-GlobalID locators, and the DSA automated-processing disclosure.
  class ReportTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @reporter = create_user
    end

    test "infers the reported user from the reportable and captures an immutable snapshot" do
      author = create_user
      comment = Comment.create!(user: author, body: "a perfectly ordinary comment")

      report = Moderate::Report.create!(
        reporter: @reporter,
        reportable: comment,
        reported_field: "body",
        category: "harassment",
        message: "This comment is abusive.",
        good_faith_confirmed: true
      )

      # reported_user is inferred from the reportable's #reported_owner (the comment's
      # author) — Report never hard-codes how ownership works.
      assert_equal author, report.reported_user

      # The snapshot is frozen JSON captured at create time, so the evidence survives
      # the content being edited or deleted afterward. We assert the structural keys
      # the model always captures (host-agnostic identity of WHAT was reported).
      snapshot = report.snapshot
      assert_equal "Comment", snapshot["reportable_type"]
      assert_equal comment.id, snapshot["reportable_id"]
      assert_equal "body", snapshot["reported_field"]
      assert_equal author.id, snapshot["reported_user_id"]
      assert_equal "a perfectly ordinary comment", snapshot["content_text"]
      assert snapshot["captured_at"].present?

      # A fresh report has not yet acknowledged receipt (DSA Art. 16(4) stamp).
      assert_nil report.acknowledged_at
    end

    test "reportable classes are auto-discovered from the reportable macro" do
      # User (participates_in_moderation -> reportable) and Comment (reportable :body) both
      # self-registered on inclusion — no manual registry.
      assert_includes Moderate.reportable_classes, User
      assert_includes Moderate.reportable_classes, Comment
    end

    test "a community report can name only a whitelisted reportable field" do
      author = create_user
      comment = Comment.create!(user: author, body: "fine") # reportable :body only

      ok = Moderate::Report.new(
        reporter: @reporter, reportable: comment, reported_field: "body",
        category: "harassment", message: "ok", good_faith_confirmed: true
      )
      assert_predicate ok, :valid?

      bad = Moderate::Report.new(
        reporter: @reporter, reportable: comment, reported_field: "user_id",
        category: "harassment", message: "nope", good_faith_confirmed: true
      )
      refute bad.valid?
      assert bad.errors[:reported_field].any?
    end

    test "a reporter cannot report their own account" do
      report = Moderate::Report.new(
        reporter: @reporter,
        reportable: @reporter, # a User is itself reportable
        reported_user: @reporter,
        reported_field: "name",
        category: "other",
        message: "self",
        good_faith_confirmed: true
      )

      refute report.valid?
      assert report.errors[:reported_user].any?
    end

    test "good-faith confirmation is required (DSA Art. 16(2)(d))" do
      comment = Comment.create!(user: create_user, body: "fine")
      report = Moderate::Report.new(
        reporter: @reporter, reportable: comment, reported_field: "body",
        category: "other", message: "x", good_faith_confirmed: false
      )
      refute report.valid?
      assert report.errors[:good_faith_confirmed].any?
    end

    test "public DSA notices require an exact electronic location (subject URL)" do
      report = Moderate::Report.new(
        category: "illegal_content",
        notifier_email: "notice@example.com",
        message: "Illegal content somewhere",
        good_faith_confirmed: true
      )

      refute report.valid?
      assert report.errors[:subject_url].any?
    end

    test "subject URLs must be http(s) — javascript: is rejected and never echoed" do
      report = Moderate::Report.new(
        category: "illegal_content",
        notifier_email: "notice@example.com",
        subject_url: "javascript:alert(1)",
        message: "Illegal content",
        good_faith_confirmed: true
      )

      refute report.valid?
      assert report.errors[:subject_url].any?
      assert_nil report.safe_subject_url
    end

    test "DSA notices require legal taxonomy, jurisdiction, content type, name, and email" do
      report = Moderate::Report.new(
        intake_kind: "dsa",
        category: "illegal_content",
        subject_url: "https://example.test/content/1",
        message: "Illegal content",
        good_faith_confirmed: true
      )

      refute report.valid?
      assert report.errors[:legal_reason].any?
      assert report.errors[:legal_country_code].any?
      assert report.errors[:content_type].any?
      assert report.errors[:notifier_name].any?
      assert report.errors[:notifier_email].any?
    end

    test "DSA child-safety notices may be anonymous; other anonymous notices may not" do
      child_safety = Moderate::Report.new(
        intake_kind: "dsa",
        anonymous: true,
        category: "illegal_content",
        legal_reason: "protection_of_minors",
        legal_country_code: "EU",
        content_type: "message",
        subject_url: "https://example.test/messages/1",
        message: "This involves child safety.",
        good_faith_confirmed: true
      )
      assert_predicate child_safety, :valid?
      assert_predicate child_safety, :anonymous_notice?

      other_anonymous = Moderate::Report.new(
        intake_kind: "dsa",
        anonymous: true,
        category: "illegal_content",
        legal_reason: "public_security",
        legal_country_code: "EU",
        content_type: "listing",
        subject_url: "https://example.test/listings/1",
        message: "This involves public security.",
        good_faith_confirmed: true
      )
      refute other_anonymous.valid?
      assert other_anonymous.errors[:anonymous].any?
    end

    test "signed reportable targets round-trip through SignedGlobalID" do
      user = create_user
      token = user.to_sgid_param(for: Moderate::Report::SIGNED_GLOBAL_ID_PURPOSE)

      assert_equal user, Moderate::Report.locate_signed_reportable(token)
      # A bogus token resolves to nil rather than raising — and the allow-list (the
      # auto-discovered reportable classes) blocks object-substitution attacks.
      assert_nil Moderate::Report.locate_signed_reportable("not-a-token")
      assert_nil Moderate::Report.locate_signed_reportable(nil)
    end

    test "signed reportable lookup falls back to the reportable contract when the registry is stale" do
      user = create_user
      token = user.to_sgid_param(for: Moderate::Report::SIGNED_GLOBAL_ID_PURPOSE)
      registry = Moderate.send(:reportable_registry)
      original_registry = registry.dup
      registry.delete(user.class.name)

      assert_equal user, Moderate::Report.locate_signed_reportable(token)
    ensure
      registry.replace(original_registry) if registry && original_registry
    end

    test "automated_processing_used? is true when an auto-flag exists for the same target+field" do
      author = create_user
      comment = Comment.create!(user: author, body: "clean text")

      # An existing system flag on the SAME (content, field) means automated means
      # already touched this content — the disclosure must say so at intake.
      Moderate::Flag.flag!(
        flaggable: comment, field: "body", owner: author, source: "text_filter", mode: "flag",
        excerpt: "x", categories: ["harassment"], scores: { "harassment" => 1.0 }, context: {}
      )

      report = Moderate::Report.create!(
        reporter: @reporter,
        reportable: comment,
        reported_field: "body",
        category: "harassment",
        message: "Already flagged by the filter.",
        good_faith_confirmed: true
      )

      assert_predicate report, :automated_processing_used?
      assert_equal true, report.automated_processing["used"]
      assert_includes report.automated_processing["sources"], "text_filter"
    end

    test "automated_processing_used? stays false for a clean report with no automation" do
      author = create_user
      comment = Comment.create!(user: author, body: "totally clean text")

      report = Moderate::Report.create!(
        reporter: @reporter,
        reportable: comment,
        reported_field: "body",
        category: "harassment",
        message: "Just a manual report.",
        good_faith_confirmed: true
      )

      refute_predicate report, :automated_processing_used?
    end

    test "the taxonomy is validated in the model (no DB check constraint)" do
      author = create_user
      comment = Comment.create!(user: author, body: "fine")

      # An unknown community category is rejected by the model's inclusion validation.
      bad_category = Moderate::Report.new(
        reporter: @reporter, reportable: comment, reported_field: "body",
        category: "definitely_not_a_category", message: "x", good_faith_confirmed: true
      )
      refute bad_category.valid?
      assert bad_category.errors[:category].any?

      # Unknown status is rejected too.
      bad_status = Moderate::Report.new(
        reporter: @reporter, reportable: comment, reported_field: "body",
        category: "harassment", message: "x", good_faith_confirmed: true, status: "frozen"
      )
      refute bad_status.valid?
      assert bad_status.errors[:status].any?

      # And an unknown DSA legal reason / country code / content type, when present.
      bad_legal = Moderate::Report.new(
        intake_kind: "dsa", category: "illegal_content",
        legal_reason: "not_a_reason", legal_country_code: "ZZ", content_type: "spaceship",
        notifier_name: "N", notifier_email: "n@example.com",
        subject_url: "https://example.test/x", message: "x", good_faith_confirmed: true
      )
      refute bad_legal.valid?
      assert bad_legal.errors[:legal_reason].any?
      assert bad_legal.errors[:legal_country_code].any?
      assert bad_legal.errors[:content_type].any?
    end

    test "a host-added community category (config.report_categories) is accepted" do
      author = create_user
      comment = Comment.create!(user: author, body: "fine")

      # A host that needs its own community label sets config.report_categories — no
      # migration required, since `category` is validated in the model (not by a DB
      # check constraint) against Report.report_categories.
      Moderate.config.report_categories = %w[harassment ban_evasion]

      ok = Moderate::Report.new(
        reporter: @reporter, reportable: comment, reported_field: "body",
        category: "ban_evasion", message: "host-specific category", good_faith_confirmed: true
      )
      assert_predicate ok, :valid?

      # And once the host narrows the list, a previously-default category is rejected.
      gone = Moderate::Report.new(
        reporter: @reporter, reportable: comment, reported_field: "body",
        category: "spam", message: "no longer in the host's list", good_faith_confirmed: true
      )
      refute gone.valid?
      assert gone.errors[:category].any?
    end

    test "report_categories falls back to DEFAULT_CATEGORIES when the host sets none" do
      # No config override (the test setup leaves it nil) ⇒ the gem default list.
      assert_equal Moderate::Report::DEFAULT_CATEGORIES, Moderate::Report.report_categories
    end

    test "resolution note is required once a report is closed" do
      author = create_user
      comment = Comment.create!(user: author, body: "fine comment")
      report = Moderate::Report.create!(
        reporter: @reporter, reportable: comment,
        reported_field: "body", category: "other",
        message: "x", good_faith_confirmed: true
      )

      report.status = "actioned"
      refute report.valid?
      assert report.errors[:resolution_note].any?
    end

    private

    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end
  end
end
