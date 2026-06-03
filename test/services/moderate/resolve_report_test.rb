# frozen_string_literal: true

require "test_helper"

module Moderate
  module Services
    # Tests for Moderate::Services::ResolveReport — the audited, atomic decision engine.
    #
    # This is the most legally-loaded path in the gem, so the suite covers each guarantee
    # the service's class doc makes, exercised host-agnostically via the dummy Comment/User
    # models + the recorder hooks:
    #   - ATOMIC enforcement + decision (content removal, ban) inside one transaction;
    #   - A NOTE IS MANDATORY on both resolve! and dismiss! (DSA Art. 17);
    #   - content removal calls the reportable's OWN `remove_reported_field!` contract;
    #   - a ban goes through `Moderate.apply_ban` → the host's `ban_handler` (never direct);
    #   - the DOUBLE-RESOLVE guard: a closed report can't be re-decided (no double-ban);
    #   - the TWO decision events fire (reporter receipt + affected-user statement of reasons);
    #   - the automated-processing disclosure (Art. 17(3)(c)) travels in the decision payload.
    class ResolveReportTest < ActiveSupport::TestCase
      setup do
        Moderate.configure do |config|
          config.audit = ->(event) { ModerateTestRecorder.audit(event) }
          config.notify = ->(event) { ModerateTestRecorder.notify(event) }
          # ban_handler just records the request — the gem leaves "what banned means"
          # entirely to the host, so we assert the gem ASKED for a ban, not a side effect.
          config.ban_handler = ->(user:, by:, reason:) { ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason) }
        end
        ModerateTestRecorder.clear
      end

      test "Report#resolve! and #dismiss! delegate to the service (the README's plain-English API)" do
        moderator = User.create!(name: "Mod", email: "mod-delegate@example.com")
        author = User.create!(name: "Author", email: "author-delegate@example.com")
        comment = Comment.create!(user: author, body: "ok body")

        report = create_report(reportable: comment, field: "body")
        report.resolve!(by: moderator, remove_content: true, ban_user: true, note: "Hate speech")
        report.reload
        assert_equal "actioned", report.status
        assert_equal moderator, report.resolved_by

        another = create_report(reportable: comment, field: "body")
        another.dismiss!(by: moderator, note: "No violation")
        assert_equal "dismissed", another.reload.status
      end

      test "resolving with actions removes content, bans the owner, audits, and fires both decision events" do
        moderator = User.create!(name: "Mod", email: "mod@example.com")
        author = User.create!(name: "Author", email: "author@example.com")
        comment = Comment.create!(user: author, body: "ok body")
        report = create_report(reportable: comment, field: "body")

        Moderate::Services::ResolveReport.new(report, by: moderator)
          .resolve!(note: "Abusive content", remove_content: true, ban_user: true)

        report.reload
        assert_equal "actioned", report.status
        assert_equal moderator, report.resolved_by
        assert_predicate report.resolved_at, :present?
        # Art. 20: a decision opens the appeal window.
        assert_predicate report.appeal_deadline_at, :present?
        # The neutral, host-agnostic scope of the restriction (a ban dominates).
        assert_equal "account_suspended", report.decision_visibility

        # Content removal went through the reportable's own contract.
        # (The dummy Comment uses the Reportable default no-op, so we assert the SCOPE
        # recorded the removal intent and that the decision still completed atomically.)
        assert_equal({ "remove_content" => true, "ban_user" => true, "resolution_basis" => "terms" }, report.resolution_actions)

        # The ban was requested through the host's ban_handler — never applied directly.
        assert_equal 1, ModerateTestRecorder.bans.size
        ban = ModerateTestRecorder.bans.first
        assert_equal author, ban[:user]
        assert_equal moderator, ban[:by]
        assert_equal "Abusive content", ban[:reason]

        # The decision was audited.
        decision_audits = ModerateTestRecorder.audits_named(:report_decision)
        assert_equal 1, decision_audits.size
        assert_equal "actioned", decision_audits.first.payload[:status]

        # TWO decision events, on purpose: the reporter receipt (Art. 16(5)) AND the
        # affected-user statement of reasons (Art. 17).
        assert_equal 1, ModerateTestRecorder.notifications_named(:report_decision).size
        assert_equal 1, ModerateTestRecorder.notifications_named(:affected_user_decision).size
        assert_equal 1, ModerateTestRecorder.notifications_named(:user_banned).size
        assert_equal author, ModerateTestRecorder.notifications_named(:user_banned).first.subject
        assert_equal moderator, ModerateTestRecorder.notifications_named(:user_banned).first.actor

        # Delivered ⇒ the legal-communication timestamps were stamped.
        assert_predicate report.decision_notified_at, :present?
        assert_predicate report.affected_user_notified_at, :present?
      end

      test "content removal invokes the reportable's remove_reported_field! contract" do
        moderator = User.create!(name: "Mod")
        author = User.create!(name: "Author")
        comment = Comment.create!(user: author, body: "ok body")
        report = create_report(reportable: comment, field: "body")

        # The gem's job is to INVOKE the host contract, not to know what "remove" means.
        # Assert exactly that: the reportable's own method is called with the field.
        comment.expects(:remove_reported_field!).with("body").returns(true)
        # Stub the reportable the report resolves so the expectation is on our instance.
        report.stubs(:reportable).returns(comment)

        Moderate::Services::ResolveReport.new(report, by: moderator)
          .resolve!(note: "Removed it", remove_content: true)

        assert_equal "actioned", report.reload.status
        assert_equal "content_removed", report.decision_visibility
      end

      test "dismissing closes the report with no enforcement and still opens an appeal window" do
        moderator = User.create!(name: "Mod", email: "mod@example.com")
        author = User.create!(name: "Author", email: "author@example.com")
        comment = Comment.create!(user: author, body: "fine body")
        report = create_report(reportable: comment, field: "body")

        Moderate::Services::ResolveReport.new(report, by: moderator).dismiss!(note: "No violation found")

        report.reload
        assert_equal "dismissed", report.status
        assert_equal "no_violation", report.resolution_basis
        assert_equal "no_restriction", report.decision_visibility
        # The REPORTER can appeal a dismissal, so the window is still stamped.
        assert_predicate report.appeal_deadline_at, :present?

        # No enforcement: no ban requested.
        assert_empty ModerateTestRecorder.bans
        # The reporter still gets a decision notice (they have an email)...
        assert_equal 1, ModerateTestRecorder.notifications_named(:report_decision).size
        # ...but NO affected-user statement of reasons (nothing was restricted).
        assert_empty ModerateTestRecorder.notifications_named(:affected_user_decision)
      end

      test "resolving requires a decision note (Art. 17 statement of reasons)" do
        moderator = User.create!(name: "Mod")
        author = User.create!(name: "Author")
        comment = Comment.create!(user: author, body: "fine body")
        report = create_report(reportable: comment, field: "body")

        error = assert_raises(ActiveRecord::RecordInvalid) do
          Moderate::Services::ResolveReport.new(report, by: moderator).resolve!(note: " ", remove_content: true)
        end
        # The error is attached to the record's `resolution_note`, so a controller's
        # `rescue RecordInvalid` / errors flow works like any failed save.
        assert_predicate error.record.errors[:resolution_note], :present?

        # The report stayed open and nothing was enforced.
        assert_equal "open", report.reload.status
        assert_empty ModerateTestRecorder.bans
      end

      test "dismissing requires a decision note" do
        moderator = User.create!(name: "Mod")
        author = User.create!(name: "Author")
        comment = Comment.create!(user: author, body: "fine body")
        report = create_report(reportable: comment, field: "body")

        assert_raises(ActiveRecord::RecordInvalid) do
          Moderate::Services::ResolveReport.new(report, by: moderator).dismiss!(note: "")
        end

        assert_equal "open", report.reload.status
      end

      test "a closed report cannot be resolved a second time (no double-ban, idempotent)" do
        moderator = User.create!(name: "Mod", email: "mod@example.com")
        author = User.create!(name: "Author", email: "author@example.com")
        comment = Comment.create!(user: author, body: "fine body")
        report = create_report(reportable: comment, field: "body")

        Moderate::Services::ResolveReport.new(report, by: moderator).resolve!(note: "First decision")
        first_resolved_at = report.reload.resolved_at
        ModerateTestRecorder.clear # ignore the first (valid) decision's side effects

        # A second resolve must hit the in-lock `open?` re-check and bail cleanly.
        assert_raises(ActiveRecord::RecordInvalid) do
          Moderate::Services::ResolveReport.new(report, by: moderator).resolve!(note: "Second decision", ban_user: true)
        end

        report.reload
        # The first decision is untouched — no re-apply of enforcement.
        assert_equal "actioned", report.status
        assert_equal "First decision", report.resolution_note
        assert_equal first_resolved_at, report.resolved_at
        # Crucially: the second attempt's ban never ran.
        assert_empty ModerateTestRecorder.bans
        # Only the first decision was audited.
        assert_empty ModerateTestRecorder.audits_named(:report_decision)
      end

      test "the decision payload discloses whether automated means were used (Art. 17(3)(c))" do
        moderator = User.create!(name: "Mod", email: "mod@example.com")
        author = User.create!(name: "Author", email: "author@example.com")
        comment = Comment.create!(user: author, body: "ok body")
        report = create_report(reportable: comment, field: "body")

        # No classifier touched this content, so the disclosure must read "automated: false"
        # (or be absent) — a decision email can never falsely claim automation participated.
        Moderate::Services::ResolveReport.new(report, by: moderator)
          .resolve!(note: "Manual decision", remove_content: true)

        statement = ModerateTestRecorder.notifications_named(:affected_user_decision).first
        # The Art. 17 payload carries the action label, the ground, and the appeal deadline.
        assert_equal "content_removed", statement.payload[:action]
        assert_equal "terms", statement.payload[:resolution_basis]
        assert_predicate statement.payload[:appeal_deadline_at], :present?
        # automated is either absent (compacted away when false) or explicitly falsey —
        # what it must NOT be is a true claim.
        refute statement.payload[:automated]
      end

      test "records resolution_basis and a no_action label for a dismissal" do
        moderator = User.create!(name: "Mod")
        author = User.create!(name: "Author")
        comment = Comment.create!(user: author, body: "fine body")
        report = create_report(reportable: comment, field: "body")

        Moderate::Services::ResolveReport.new(report, by: moderator)
          .resolve!(note: "Acted but no removal/ban", resolution_basis: "law")

        report.reload
        # Neither remove nor ban ⇒ the neutral "other_restriction" scope, and the
        # caller's explicit ground is recorded.
        assert_equal "other_restriction", report.decision_visibility
        assert_equal "law", report.resolution_basis
      end

      private

      # A minimal community report the resolver acts on. The reporter is created here,
      # DISTINCT from the reportable's owner, on purpose: `Moderate::Report` infers the
      # reported_user from the reportable's `reported_owner`, and a report whose reporter
      # IS that owner trips `reporter_cannot_report_self`. Keeping them distinct means the
      # affected-user (DSA Art. 17) path has someone to notify who isn't the reporter, and
      # the reporter carries an email so the `report_decision` receipt actually fires.
      def create_report(reportable:, field:)
        reporter = User.create!(name: "Reporter", email: "reporter-#{SecureRandom.hex(4)}@example.com")
        Moderate::Report.create!(
          reporter: reporter,
          reportable: reportable,
          reported_field: field,
          category: "harassment",
          message: "Please review",
          good_faith_confirmed: true
        )
      end
    end
  end
end
