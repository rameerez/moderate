# frozen_string_literal: true

require "test_helper"

# The WEB-surface reporting behavior: the `moderate_report_link` view helper that a
# host drops next to any reportable content, plus the in-app `report!` write path that
# the link ultimately feeds.
#
# `moderate_report_link` is the affordance Apple Guideline 1.2 and Google Play's UGC
# policy require every social/UGC app to surface next to user-generated content:
#   - https://developer.apple.com/app-store/review/guidelines/#user-generated-content
#   - https://support.google.com/googleplay/android-developer/answer/9876937
# Its load-bearing contract is "render NOTHING unless this viewer may report this
# field" — so a host can sprinkle the helper across a template without guarding each
# call site (the helper IS the guard). We test that contract directly by rendering the
# helper through a real ActionView context with a stubbed current viewer.
class ReportingTest < ActiveSupport::TestCase
  # A throwaway host controller used ONLY to mint a real view context. It stands in for
  # the host's own ApplicationController: the gem's EngineHelper is mixed into ActionView
  # for the host (via the on_load(:action_view) hook), and we expose `current_user` to
  # the view with `helper_method` — the standard, Rails-version-stable way to render a
  # helper that depends on the signed-in viewer. The viewer is held on the controller
  # INSTANCE (set per `view_context` call), so there's no shared class state to leak.
  class FakeHostController < ActionController::Base
    attr_accessor :test_viewer
    helper_method :current_user
    def current_user = test_viewer
  end

  setup do
    @author = User.create!(name: "Author", email: "author@example.com")
    @viewer = User.create!(name: "Viewer", email: "viewer@example.com")
    @comment = Comment.create!(user: @author, body: "a perfectly fine comment")
    ModerateTestRecorder.clear
    rewire_hooks
  end

  # --- report_link visibility (the helper's whole contract) -------------------

  test "moderate_report_link renders an anchor when a signed-in viewer may report the field" do
    html = render_report_link(@comment, viewer: @viewer, field: :body)

    refute_nil html, "the link should render for a permitted viewer"
    assert_includes html, "<a", "it renders an <a> tag"
    assert_includes html, "Report", "default label is the translated 'Report'"
    # The target is passed as a SIGNED GID (never a raw type+id), so the URL must NOT
    # leak the raw class name / primary key of the reported record.
    refute_includes html, "Comment", "the raw reportable_type must not appear in the URL"
    refute_includes html, "reportable_id", "no raw id param"
  end

  test "moderate_report_link renders NOTHING for an anonymous viewer (no current_user)" do
    # nil viewer => the in-app button is hidden (anonymous users use the public DSA
    # notice form instead). This is one of the three documented "render nothing" cases.
    assert_nil render_report_link(@comment, viewer: nil, field: :body)
  end

  test "moderate_report_link renders NOTHING when the viewer is the content owner (no self-report)" do
    # Moderate::Actor#report_visible_to? forbids reporting your own content, so the
    # helper hides the control on the author's own view of it.
    assert_nil render_report_link(@comment, viewer: @author, field: :body)
  end

  test "moderate_report_link renders NOTHING for a field that isn't reportable" do
    # Comment declares `reportable :body` only, so :title is not a reportable field and
    # report_visible_to? returns false => the helper renders nothing.
    assert_nil render_report_link(@comment, viewer: @viewer, field: :title)
  end

  test "moderate_report_link renders NOTHING for an object that isn't reportable at all" do
    # A plain object that doesn't respond to report_visible_to? must render nothing,
    # not explode — the helper is safe to call on anything.
    plain = Object.new
    assert_nil render_report_link(plain, viewer: @viewer, field: :body)
  end

  test "moderate_report_link accepts a custom label and passes through HTML options" do
    html = render_report_link(@comment, viewer: @viewer, field: :body,
                              label: "Flag this", html_options: { class: "report-btn", "data-test": "x" })

    assert_includes html, "Flag this"
    assert_includes html, "report-btn"
    assert_includes html, "data-test"
  end

  test "report_link is an exact alias of moderate_report_link" do
    view = view_context(viewer: @viewer)
    a = view.moderate_report_link(@comment, field: :body)
    b = view.report_link(@comment, field: :body)
    assert_equal a, b
  end

  # --- The write path the link feeds (in-app report!) -------------------------

  test "report! files a community report against the content and drops it in the queue" do
    report = nil
    assert_difference -> { Moderate::Report.count }, 1 do
      report = @viewer.report!(@comment, category: :harassment, details: "won't stop")
    end

    assert_equal @viewer, report.reporter
    assert_equal @comment, report.reportable
    assert_equal "community", report.intake_kind
    assert_equal "harassment", report.category
    assert_equal "won't stop", report.message
    # reported_user is inferred from the reportable's reported_owner (Comment -> author).
    assert_equal @author, report.reported_user
    assert report.open?, "a fresh report awaits a decision"
    assert_includes Moderate::Report.pending, report
    assert_predicate report.acknowledged_at, :present?
    assert_equal 1, ModerateTestRecorder.audits_named(:report_received).size
    assert_equal 1, ModerateTestRecorder.notifications_named(:report_received).size
  end

  test "report! against a field not on the reportable whitelist is rejected" do
    # Comment#reportable_field_allowed?("title") is false (it declares `reportable :body`
    # only), so the Report's reportable_field_must_be_allowed validation rejects it.
    # `reported_field` is the Report column the helper's `field` query param maps to.
    assert_raises(ActiveRecord::RecordInvalid) do
      @viewer.report!(@comment, category: :harassment, reported_field: "title")
    end
  end

  test "report! naming the declared reportable field is accepted" do
    report = @viewer.report!(@comment, category: :harassment, reported_field: "body", details: "abusive")
    assert report.persisted?
    assert_equal "body", report.reported_field
  end

  test "report! consumes both field aliases and prefers reported_field" do
    report = @viewer.report!(
      @comment,
      category: :harassment,
      reported_field: "body",
      field: "title",
      details: "abusive"
    )

    assert report.persisted?
    assert_equal "body", report.reported_field
  end

  test "a user cannot report themselves" do
    # Pass a valid message and a declared reportable field ("name" is User's only
    # reportable field) so the ONLY thing that can fail is the self-report guard
    # (reporter_cannot_report_self) — not a missing-message or bad-field validation.
    error = assert_raises(ActiveRecord::RecordInvalid) do
      @viewer.report!(@viewer, category: :impersonation, reported_field: "name", details: "this is me")
    end
    assert_includes error.record.errors.attribute_names, :reported_user
  end

  private

  # Render `moderate_report_link` through a real ActionView context whose
  # `current_user` is `viewer`. Returns the rendered String, or nil when the helper
  # rendered nothing (its "not permitted" contract).
  def render_report_link(record, viewer:, field: nil, label: nil, html_options: {})
    view_context(viewer: viewer).moderate_report_link(record, field: field, label: label, **html_options)
  end

  # Build a real host-controller view context whose `current_user` is `viewer`. A
  # controller-minted view_context is the version-stable way to get a fully wired
  # ActionView (link_to, helper modules, the controller's helper_methods) without
  # hand-constructing ActionView::Base. The helper's path resolution falls back to a
  # conventional "/reports/new?..." since the dummy exposes no host report route
  # (BYOUI) — exactly the documented fallback — so link_to just needs a plain String
  # href and no router is required.
  def view_context(viewer:)
    controller = FakeHostController.new
    controller.test_viewer = viewer
    # Give the controller a minimal request so view_context can build (url helpers /
    # default_url_options read from it); we never actually generate a host route here.
    controller.request = ActionDispatch::TestRequest.create
    controller.view_context
  end

  def rewire_hooks(config = Moderate.config)
    config.audit = ->(event) { ModerateTestRecorder.audit(event) }
    config.notify = ->(event) { ModerateTestRecorder.notify(event) }
    config.on_block = ->(blocker:, blocked:, at:) { ModerateTestRecorder.on_block(blocker: blocker, blocked: blocked, at: at) }
    config.ban_handler = ->(user:, by:, reason:) { ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason) }
    config
  end
end
