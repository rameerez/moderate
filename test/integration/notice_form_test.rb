# frozen_string_literal: true

require "test_helper"

# The PUBLIC DSA Article 16 "notice and action" form — the mountable engine surface
# (the "Report illegal content (EU)" page you see at the bottom of X / YouTube /
# Reddit). These are HTTP-level integration tests against the engine as a real host
# mounts it (the dummy mounts it at "/trust", NOT "/legal" — the gem hardcodes no
# prefix; the host chooses the path). See docs/dsa-notice-form.md.
# https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Article 16)
#
# What we prove:
#   - GET /trust/notices/new renders, and PREFILLS the reported-content fields from
#     the X-style query string (content_url/content_type/content_author/content_id),
#     leaving those fields EDITABLE (Art. 16(2)(b));
#   - when a Devise-style `current_user` is signed in, the IDENTITY fields
#     (name/email) prefill AND lock (readonly), while content fields stay editable
#     (Art. 16(2)(c)); and the controller re-asserts identity server-side so a
#     tampered submit can't spoof it;
#   - POST /trust/notices with a well-formed notice CREATES a Moderate::Report with
#     intake_kind "dsa" (the intake still runs), acknowledges it, and confirms receipt;
#   - the bot gate auto-integrates `rails_cloudflare_turnstile` when present (we stub
#     the gem's module + helper/exception) — a failed challenge blocks the create and
#     the widget renders — and falls back to the configurable `config.notice_guard`
#     proc (no-op default) when the gem is absent.
class NoticeFormTest < ActionDispatch::IntegrationTest
  # The mounted prefix in the dummy (docs say the HOST picks this; the dummy uses
  # "/trust" precisely to prove the gem hardcodes no "/legal").
  NEW = "/trust/notices/new"
  CREATE = "/trust/notices"

  setup do
    # The engine's ApplicationController applies `protect_from_forgery`, and the
    # dummy has no config/environments/test.rb to disable forgery protection, so a
    # raw integration POST would 422 on a missing CSRF token. Disable it for the
    # duration of these tests (the standard ActionDispatch idiom) so we exercise the
    # gate/intake logic, not Rails' CSRF machinery; restored in teardown.
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false

    # Re-point the hooks at the recorder (the suite's setup reset! wiped them) so we
    # can assert the confirmation-of-receipt event and the audit fired. We also DISABLE
    # the per-IP rate limit: every integration request comes from the same loopback IP
    # and the dummy uses a process-local :memory_store, so the default { max: 5 } would
    # otherwise accumulate across these POST tests and 429 the later ones. Rate
    # limiting isn't what this file exercises (it's tested elsewhere), so we turn it off.
    Moderate.configure do |config|
      config.audit = ->(event) { ModerateTestRecorder.audit(event) }
      config.notify = ->(event) { ModerateTestRecorder.notify(event) }
      config.notice_rate_limit = false
    end
    ModerateTestRecorder.clear
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    NoticeFormTest.unstub_turnstile!
  end

  # --- Prefill: reported-content fields (editable) ---------------------------

  test "GET new prefills the reported-content fields from the X-style query string and keeps them editable" do
    get NEW, params: {
      content_url: "https://example.test/p/123",
      content_type: "message",
      content_author: "baduser"
    }
    assert_response :success

    # subject_urls (Art. 16(2)(b)) prefilled into an EDITABLE text area — no readonly.
    assert_select "textarea[name=?]", "notice[subject_urls]" do |els|
      assert_equal "https://example.test/p/123", els.first.text
      assert_nil els.first["readonly"], "the reported-content URL must stay editable"
    end
    # content_type prefilled as the selected option.
    assert_select "select[name=?] option[selected][value=?]", "notice[content_type]", "message"
    # content_author prefilled into the (editable) reported_account_identifier.
    assert_select "input[name=?]", "notice[reported_account_identifier]" do |els|
      assert_equal "baduser", els.first["value"]
      assert_nil els.first["readonly"], "the reported-content handle must stay editable"
    end
  end

  test "GET new ignores a junk content_type query param (only a valid bucket is echoed)" do
    # A crafted ?content_type can't pre-poison the select — only a value the model's
    # inclusion validation accepts is echoed as selected.
    get NEW, params: { content_type: "<script>alert(1)</script>" }
    assert_response :success
    assert_select "select[name=?] option[selected]", "notice[content_type]", false,
      "a junk content_type must not be selected"
  end

  test "GET new renders a blank form with no query string" do
    get NEW
    assert_response :success
    assert_select "form"
    # The URL field renders, with no prefilled value.
    assert_select "textarea[name=?]", "notice[subject_urls]" do |els|
      assert els.first.text.empty?, "subject_urls should be blank with no query string"
    end
  end

  # --- Prefill + LOCK: identity fields ---------------------------------------

  test "GET new prefills AND locks the identity fields when a current_user is signed in" do
    user = User.create!(name: "Jane Notifier", email: "jane@example.com")
    with_current_user(user) do
      get NEW
      assert_response :success

      # name/email prefilled from current_user AND readonly (locked).
      assert_select "input[name=?][readonly]", "notice[notifier_name]" do |els|
        assert_equal "Jane Notifier", els.first["value"]
      end
      assert_select "input[name=?][readonly]", "notice[notifier_email]" do |els|
        assert_equal "jane@example.com", els.first["value"]
      end

      # The reported-content fields are STILL editable even when identity is locked.
      assert_select "textarea[name=?]", "notice[subject_urls]" do |els|
        assert_nil els.first["readonly"], "the reported-content URL stays editable"
      end
    end
  end

  test "GET new leaves identity fields editable for an anonymous visitor (no current_user)" do
    get NEW
    assert_response :success
    assert_select "input[name=?]", "notice[notifier_name]" do |els|
      assert_nil els.first["readonly"], "name is editable for an anonymous notifier"
    end
    assert_select "input[name=?]", "notice[notifier_email]" do |els|
      assert_nil els.first["readonly"], "email is editable for an anonymous notifier"
    end
  end

  test "POST create re-asserts the locked identity from current_user, ignoring a tampered name/email" do
    user = User.create!(name: "Jane Notifier", email: "jane@example.com")
    with_current_user(user) do
      assert_difference -> { Moderate::Report.count }, 1 do
        post CREATE, params: { notice: well_formed_notice_params.merge(
          notifier_name: "Spoofed Attacker",
          notifier_email: "attacker@evil.test"
        ) }
      end
      report = Moderate::Report.last
      # The controller overwrote the posted identity with current_user's — no spoof.
      assert_equal "jane@example.com", report.notifier_email
      assert_equal "Jane Notifier", report.notifier_name
    end
  end

  # --- The intake still creates a Moderate::Report ---------------------------

  test "POST create with a well-formed anonymous notice creates a dsa Moderate::Report, acknowledged + confirmed" do
    assert_difference -> { Moderate::Report.count }, 1 do
      post CREATE, params: { notice: well_formed_notice_params }
    end
    assert_response :see_other
    assert_redirected_to NEW

    report = Moderate::Report.last
    assert_equal "dsa", report.intake_kind
    assert_predicate report, :dsa?
    assert_equal "public_security", report.legal_reason
    assert_equal "ES", report.legal_country_code
    assert_equal "https://example.test/illegal", report.subject_url
    assert_predicate report.acknowledged_at, :present?, "Art. 16(4) durable acknowledgement"

    # The confirmation-of-receipt event went to the notifier (Art. 16(4)).
    receipts = ModerateTestRecorder.notifications_named(:notice_received)
    assert_equal 1, receipts.size
    assert_equal "notifier@example.com", receipts.first.recipients.first.email
    assert_empty ModerateTestRecorder.notifications_named(:report_received)
    # And the shared intake path audited it.
    assert_equal 1, ModerateTestRecorder.audits_named(:report_received).size
  end

  test "POST create accepts newline-separated exact URLs" do
    params = well_formed_notice_params.except(:subject_url).merge(
      subject_urls: "https://example.test/illegal\nhttps://example.test/also-illegal"
    )

    assert_difference -> { Moderate::Report.count }, 1 do
      post CREATE, params: { notice: params }
    end

    report = Moderate::Report.last
    assert_equal "https://example.test/illegal", report.subject_url
    assert_equal [
      "https://example.test/illegal",
      "https://example.test/also-illegal"
    ], report.subject_urls
  end

  test "POST create with an invalid notice re-renders the form 422 and creates nothing" do
    assert_no_difference -> { Moderate::Report.count } do
      post CREATE, params: { notice: well_formed_notice_params.merge(legal_reason: "") }
    end
    assert_response :unprocessable_entity
    assert_select "form"
    assert_empty ModerateTestRecorder.notifications_named(:notice_received)
  end

  # --- Bot gate: no-op fallback when the Turnstile gem is ABSENT --------------

  test "with no Turnstile gem and the default no-op notice_guard, create just works" do
    # The gem isn't in the bundle, so the controller's fallback (config.notice_guard,
    # no-op default) governs the gate — and the form must work untouched.
    refute defined?(::RailsCloudflareTurnstile),
      "this test asserts the gem-ABSENT branch; it must not be loaded"
    assert_difference -> { Moderate::Report.count }, 1 do
      post CREATE, params: { notice: well_formed_notice_params }
    end
    assert_response :see_other
  end

  test "a configured notice_guard that returns false blocks the create (gem-absent path)" do
    Moderate.config.notice_guard = ->(_controller) { false }
    assert_no_difference -> { Moderate::Report.count } do
      post CREATE, params: { notice: well_formed_notice_params }
    end
    assert_response :unprocessable_entity
    assert_match(/verify/i, flash[:alert].to_s)
  end

  test "a configured notice_guard that returns true allows the create (gem-absent path)" do
    Moderate.config.notice_guard = ->(_controller) { true }
    assert_difference -> { Moderate::Report.count }, 1 do
      post CREATE, params: { notice: well_formed_notice_params }
    end
    assert_response :see_other
  end

  test "a notice_guard that raises fails closed (gem-absent path) and never 500s the form" do
    Moderate.config.notice_guard = ->(_controller) { raise "boom" }
    assert_no_difference -> { Moderate::Report.count } do
      post CREATE, params: { notice: well_formed_notice_params }
    end
    assert_response :unprocessable_entity
  end

  test "the no-op notice_guard does not render the Turnstile widget when the gem is absent" do
    get NEW
    assert_response :success
    assert_select "div.cf-turnstile-stub", false, "no widget without the gem"
  end

  # --- Bot gate: auto-integration when the Turnstile gem IS present -----------
  #
  # The gem isn't in the gem's own test bundle, so we STUB its real surface: the
  # top-level RailsCloudflareTurnstile module (so `defined?` is truthy), its
  # `Forbidden` exception (the controller's rescue target), the controller's
  # `validate_cloudflare_turnstile` verifier (pass or raise Forbidden per `pass:`,
  # recording that it ran), and the view's `cloudflare_turnstile` helpers. We mix the
  # methods into the live engine controller/ActionView the same way the gem's railtie
  # does. The gate is decided AT REQUEST TIME (`turnstile_available?`), so no
  # controller reload is needed — stubbing the module + method is enough.
  # https://github.com/instrumentl/rails-cloudflare-turnstile

  test "when the Turnstile gem is present, the controller verifies it and the view renders the widget" do
    NoticeFormTest.stub_turnstile!(pass: true)

    get NEW
    assert_response :success
    assert_select "div.cf-turnstile-stub", 1, "the widget renders when the gem is present"

    assert_difference -> { Moderate::Report.count }, 1 do
      post CREATE, params: { notice: well_formed_notice_params }
    end
    assert_response :see_other
    assert NoticeFormTest.turnstile_verified, "the controller ran the gem's verifier"
  end

  test "when the Turnstile gem is present and the challenge FAILS, create is blocked with a friendly 422" do
    NoticeFormTest.stub_turnstile!(pass: false)

    assert_no_difference -> { Moderate::Report.count } do
      post CREATE, params: { notice: well_formed_notice_params }
    end
    assert_response :unprocessable_entity
    assert_match(/verify/i, flash[:alert].to_s)
    assert NoticeFormTest.turnstile_verified, "the gem's verifier ran before failing"
  end

  test "with the Turnstile gem present, the gate does NOT consult config.notice_guard" do
    # When the gem is present, path (1) wins outright; the fallback guard must not run.
    guard_ran = false
    Moderate.config.notice_guard = ->(_controller) { guard_ran = true }
    NoticeFormTest.stub_turnstile!(pass: true)

    post CREATE, params: { notice: well_formed_notice_params }
    assert_response :see_other
    refute guard_ran, "the configurable guard must be bypassed when Turnstile is present"
  end

  test "a configured human verification skip bypasses Turnstile and hides the widget" do
    NoticeFormTest.stub_turnstile!(pass: false)
    Moderate.config.notice_human_verification_skip_if = ->(controller) {
      controller.request.user_agent.to_s.include?("Hotwire Native")
    }
    headers = { "User-Agent" => "Hotwire Native iOS" }

    get NEW, headers: headers
    assert_response :success
    assert_select "div.cf-turnstile-stub", false, "skipped requests should not render a browser captcha"

    assert_difference -> { Moderate::Report.count }, 1 do
      post CREATE, params: { notice: well_formed_notice_params }, headers: headers
    end
    assert_response :see_other
    refute NoticeFormTest.turnstile_verified, "the verifier should not run for skipped requests"
  end

  # --- Turnstile stubbing helpers (class-level so setup/teardown can reset) ----

  class << self
    attr_accessor :turnstile_verified

    # Define a minimal RailsCloudflareTurnstile that quacks like the real gem and mix
    # its helpers into the live classes (controller verifier + view widget), exactly
    # as the gem's railtie would. `pass:` controls whether the verifier passes or
    # raises the gem's Forbidden exception.
    def stub_turnstile!(pass:)
      self.turnstile_verified = false
      test_class = self

      unless defined?(::RailsCloudflareTurnstile)
        mod = Module.new
        mod.const_set(:Forbidden, Class.new(StandardError))
        Object.const_set(:RailsCloudflareTurnstile, mod)
      end
      # `attr_accessor` is private on Module, so reach it via `send` to add a tiny
      # test-only switch the stubbed verifier reads.
      ::RailsCloudflareTurnstile.singleton_class.send(:attr_accessor, :__test_pass)
      ::RailsCloudflareTurnstile.__test_pass = pass

      controller_helpers = Module.new do
        define_method(:validate_cloudflare_turnstile) do
          test_class.turnstile_verified = true
          raise ::RailsCloudflareTurnstile::Forbidden unless ::RailsCloudflareTurnstile.__test_pass
        end
      end
      view_helpers = Module.new do
        def cloudflare_turnstile = %(<div class="cf-turnstile-stub"></div>).html_safe
        def cloudflare_turnstile_script_tag = "".html_safe
      end

      # Mix the methods into the live classes the same way the gem's railtie does.
      Moderate::ApplicationController.include(controller_helpers)
      ActionView::Base.include(view_helpers)
    end

    # Remove the stubbed module so `defined?(::RailsCloudflareTurnstile)` is false
    # again for the gem-absent tests. The helper modules previously mixed into
    # ApplicationController/ActionView are inert once the module is gone: the
    # controller's `turnstile_available?` returns false (no module) and the view's
    # widget block is `defined?`-guarded, so neither path fires.
    def unstub_turnstile!
      Object.send(:remove_const, :RailsCloudflareTurnstile) if defined?(::RailsCloudflareTurnstile)
      self.turnstile_verified = false
    end
  end

  private

  # Drive a "signed-in user" through the integration stack. The engine's base
  # controller doesn't define `current_user` (the dummy's parent is
  # ActionController::Base), so we define it ON that base for the block's duration —
  # exactly the Devise-style `current_user` the controller detects via `respond_to?`.
  def with_current_user(user)
    Moderate::ApplicationController.define_method(:current_user) { user }
    yield
  ensure
    if Moderate::ApplicationController.method_defined?(:current_user)
      Moderate::ApplicationController.send(:remove_method, :current_user)
    end
  end

  # A complete, valid Art. 16 notice about an external URL (no in-app reportable
  # record), so the suite exercises the pure public-notice path host-agnostically.
  def well_formed_notice_params
    {
      notifier_name: "Public Notifier",
      notifier_email: "notifier@example.com",
      legal_reason: "public_security",
      legal_country_code: "ES",
      content_type: "other",
      subject_url: "https://example.test/illegal",
      message: "This URL hosts content that breaches public security law.",
      good_faith_confirmed: "1"
    }
  end
end
