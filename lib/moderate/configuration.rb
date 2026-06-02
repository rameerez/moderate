# frozen_string_literal: true

require_relative "errors"

module Moderate
  # The single configuration object the host populates in
  # `config/initializers/moderate.rb` via `Moderate.configure do |config| ... end`.
  #
  # Design rules, straight from docs/configuration.md:
  #   - Config is read AT THE POINT OF USE, not frozen at boot. Class names are
  #     stored as strings and constantized lazily, so the initializer works no
  #     matter when the app loads (the User model may not exist yet at boot).
  #   - Validating setters normalize their input (`to_s.strip.downcase.to_sym`) so
  #     "Block", :block and " block " all mean the same thing, and raise a
  #     plain-English ArgumentError on a bad value — failing fast at the assignment
  #     line. `validate!` runs once more at the end of `configure` for cross-field
  #     checks (e.g. a :block filter pointed at an async adapter).
  #   - Every hook (`audit`/`notify`/`on_block`/`ban_handler`) defaults to a no-op,
  #     so the gem works untouched and a host wires hooks only as needed.
  #
  # This mirrors the validating-setter convention across the ecosystem
  # (usage_credits' `default_currency=`, wallets' `default_asset=`).
  class Configuration
    # The three filter modes a `moderates :field` / `config.filter` can use.
    #   :off   — no check
    #   :block — reject the save with a validation error if the filter trips
    #   :flag  — allow the save, create a Moderate::Flag after commit for review
    # Order matters for the error message ("must be one of: off, block, flag").
    FILTER_MODES = %i[off block flag].freeze

    # A per-(class, field) filter policy. `class_name` is stored as a STRING and
    # constantized lazily by the consumer, same as `user_class`, so declaring a
    # filter for a model that isn't loaded yet is fine. `adapter` is the adapter
    # NAME (a symbol) resolved against the adapters registry at classify time —
    # never the adapter object itself, so swapping a backend is a one-line change.
    FilterPolicy = Data.define(:class_name, :field, :adapter, :mode) do
      def off? = mode == :off
      def block? = mode == :block
      def flag? = mode == :flag
    end

    # --- Identity -------------------------------------------------------------
    attr_reader :user_class

    # --- Filtering ------------------------------------------------------------
    attr_reader :default_filter_mode, :filter_adapter
    attr_accessor :additional_words, :excluded_words
    attr_reader :adapters, :filters

    # --- Taxonomy (host-customizable) -----------------------------------------
    # Override the in-app COMMUNITY report category list. nil ⇒ the gem default
    # (Moderate::Report::DEFAULT_CATEGORIES). Adding a category here requires NO
    # migration: `category` is validated in the model (Moderate::Report), not by a DB
    # check constraint. (The DSA legal-reason/country taxonomies are regulator-defined
    # and NOT overridable.) A plain accessor — any value here is coerced to strings and
    # compared at validation time by Report.report_categories.
    attr_accessor :report_categories

    # --- Hooks (all no-op by default) ----------------------------------------
    attr_accessor :audit, :notify, :on_block, :ban_handler

    # --- Misc -----------------------------------------------------------------
    attr_accessor :locale

    # --- DSA notice form ------------------------------------------------------
    # Documented in docs/dsa-notice-form.md. Held here so the engine/controller
    # (written by other components) read them off the same Configuration object.
    # `notice_guard` is the gem-absent fallback bot gate (see
    # app/controllers/moderate/notices_controller.rb#verify_human!): a proc that
    # receives the controller and returns truthy to allow the POST. nil/no-op ⇒ the
    # form just works (the default). When the host installs `rails_cloudflare_turnstile`,
    # the controller auto-uses Turnstile instead and this proc is bypassed.
    attr_reader :parent_controller
    attr_accessor :notice_form_enabled, :notice_rate_limit,
                  :notice_turnstile_site_key, :notice_turnstile_secret_key,
                  :notice_captcha_verifier, :notice_guard,
                  :appeal_form_enabled, :appeal_rate_limit, :appeal_guard, :appeal_return_path,
                  :signed_gid_purposes

    def initialize
      # Identity. "User" is the overwhelmingly common case; the host overrides it
      # if their actor model is "Account", "Member", etc.
      @user_class = "User"

      # Filtering defaults. :block is the safe default per docs (reject objectionable
      # writes); :wordlist is the offline, zero-dependency default text adapter.
      @default_filter_mode = :block
      @filter_adapter = :wordlist
      @additional_words = []
      @excluded_words = []

      # Community report category override. nil ⇒ Moderate::Report::DEFAULT_CATEGORIES.
      # No migration needed to add a category — `category` is validated in the model.
      @report_categories = nil

      # Adapters registry: name (Symbol) => adapter (an object responding to
      # `classify`, OR a String class name to constantize lazily at use time, so we
      # don't force the built-in adapter files to be loaded before the initializer
      # runs). Seeded with the ONE built-in (the offline :wordlist) the README
      # documents; OpenAI/Rekognition/etc. are reference adapters in examples/ a host
      # copies in and registers — they are not shipped, loaded, or a dependency.
      #
      # The class behind this name is the gem's own adapter; we reference it by string
      # to keep this file decoupled from its load order (and there is no
      # `Moderate::Adapters` alias namespace — point straight at the Filters class).
      @adapters = {
        wordlist: "Moderate::Filters::Wordlist"
      }

      # Per-field filter policies, keyed by [class_name_string, field_string].
      @filters = {}

      # Hooks — no-ops by default. These exact signatures are documented:
      #   audit/notify take a single Moderate::Event
      #   on_block/ban_handler take keyword args
      @audit = ->(_event) {}
      @notify = ->(_event) {}
      @on_block = ->(blocker:, blocked:, at:) {}
      @ban_handler = ->(user:, by:, reason:) {}

      # Misc. nil locale ⇒ follow I18n.default_locale at use time.
      @locale = nil

      # Engine controller defaults. The parent controller defaults to a stock base so
      # the engine works even on API-only apps — the same `parent_controller`
      # indirection Devise and api_keys use.
      @parent_controller = "::ActionController::Base"

      # DSA notice-form defaults (see docs/dsa-notice-form.md). The form is on by
      # default; both bot-gates no-op when their keys are blank; the rate limit is a
      # sane per-IP throttle.
      @notice_form_enabled = true
      @notice_rate_limit = { max: 5, within: 3600 } # 1.hour, expressed in seconds to avoid an ActiveSupport dependency here
      @notice_turnstile_site_key = nil
      @notice_turnstile_secret_key = nil
      @notice_captcha_verifier = nil
      # Gem-absent fallback bot gate. nil ⇒ no extra gate (the form just works); the
      # controller only consults it when rails_cloudflare_turnstile is NOT installed.
      @notice_guard = nil

      # DSA internal complaint / appeal form defaults. Same shape as the notice
      # form: public route, optional bot gate, runtime rate limit, and a redirect
      # target the host can choose.
      @appeal_form_enabled = true
      @appeal_rate_limit = { max: 10, within: 60 }
      @appeal_guard = nil
      @appeal_return_path = "/"

      @signed_gid_purposes = %i[appeal confirm_notice unsubscribe]
    end

    def parent_controller=(value)
      name = value.is_a?(Class) ? value.name : value.to_s
      raise ArgumentError, "parent_controller can't be blank" if name.strip.empty?

      @parent_controller = name
    end

    # --- Validating setters ---------------------------------------------------

    # user_class is stored as a String (constantized lazily by `Moderate.user_class`).
    # We accept a Class or a String and reject blanks, so a `nil`/"" slip surfaces
    # at the assignment line instead of as a cryptic NameError much later.
    def user_class=(value)
      name = value.is_a?(Class) ? value.name : value.to_s
      raise ArgumentError, "user_class can't be blank" if name.strip.empty?

      @user_class = name
    end

    # default_filter_mode normalizes and validates against FILTER_MODES.
    def default_filter_mode=(value)
      @default_filter_mode = normalize_mode(value)
    end

    # filter_adapter normalizes to a symbol; existence is checked in `validate!`
    # (it may legitimately name an adapter the host registers later in the same
    # block, so we can't insist it already exists at assignment time).
    def filter_adapter=(value)
      @filter_adapter = normalize_name(value)
    end

    # --- Adapters -------------------------------------------------------------

    # Register a host adapter under a name of the host's choosing. The adapter is
    # any object responding to `classify(value) → Moderate::Result`. The name is
    # what gets recorded as `Moderate::Flag#source`, so it shows in the queue.
    #
    # Both arg orders are accepted for ergonomics:
    #   config.register_adapter :openai, OpenAIModerator.new
    #   config.register_adapter(:openai, OpenAIModerator.new)
    def register_adapter(name, adapter)
      key = normalize_name(name)
      unless adapter.is_a?(String) || adapter.is_a?(Class) || adapter.respond_to?(:classify)
        raise ArgumentError, "adapter for #{key.inspect} must respond to #classify"
      end

      @adapters[key] = adapter
    end

    # Look up a registered adapter object by name, constantizing a String/Class
    # reference (the built-ins) on first use. Returns nil for an unknown name —
    # callers decide whether that's an error (the validator/classify path raises a
    # helpful message; see Moderate.classify).
    def adapter_for(name)
      ref = @adapters[normalize_name(name)]
      return nil if ref.nil?

      resolve_adapter(ref)
    end

    def adapter_registered?(name)
      @adapters.key?(normalize_name(name))
    end

    # --- Filters --------------------------------------------------------------

    # Declare a per-field filter policy in the initializer — the twin of
    # `moderates :field, with:, mode:` on the model. Stores the policy keyed by
    # [class_name, field] so `filter_policy_for` can resolve it (including up the
    # ancestor chain) at classify time.
    def filter(class_name, field, with: nil, mode: nil)
      name = class_name.is_a?(Class) ? class_name.name : class_name.to_s
      field_s = field.to_s
      adapter = with.nil? ? @filter_adapter : normalize_name(with)
      resolved_mode = mode.nil? ? @default_filter_mode : normalize_mode(mode)

      policy = FilterPolicy.new(class_name: name, field: field_s, adapter: adapter, mode: resolved_mode)
      @filters[[name, field_s]] = policy
      policy
    end

    # --- Validation -----------------------------------------------------------

    # Cross-field validation run at the end of `Moderate.configure`. The per-setter
    # checks already caught most typos; this catches the things that need the whole
    # block resolved:
    #   - the default text adapter must actually be registered
    #   - every per-field filter must name a registered adapter
    #   - a :block-mode filter must use a SYNCHRONOUS adapter — you can't reject a
    #     save on a background result, so :block + an async adapter (e.g. a remote
    #     classifier) is a configuration error. Async adapters run in :flag mode.
    #     (README: "`:block` requires a synchronous adapter".)
    def validate!
      validate_adapter_name!(@filter_adapter, context: "filter_adapter")

      @filters.each_value do |policy|
        validate_adapter_name!(policy.adapter, context: "filter #{policy.class_name}##{policy.field}")
        validate_block_mode_adapter!(policy)
      end

      true
    end

    private

    # Normalize a free-form mode into one of FILTER_MODES, raising a plain-English
    # ArgumentError otherwise. The normalization ("Block"/" block " → :block) is
    # the ecosystem-wide convention.
    def normalize_mode(value)
      mode = value.to_s.strip.downcase.to_sym
      unless FILTER_MODES.include?(mode)
        raise ArgumentError, "default_filter_mode must be one of: #{FILTER_MODES.join(', ')}"
      end

      mode
    end

    def normalize_name(value)
      value.to_s.strip.downcase.to_sym
    end

    def validate_adapter_name!(name, context:)
      return if adapter_registered?(name)

      raise ArgumentError,
        "unknown filter adapter #{name.inspect} for #{context} — the only built-in is :wordlist; " \
        "register your own with `config.register_adapter #{name.inspect}, MyAdapter.new`"
    end

    # A :block filter needs a synchronous adapter. We treat an adapter as
    # synchronous unless it explicitly declares `synchronous? == false` (an adapter
    # may expose a `synchronous?`/`async?` predicate — the built-in Filters::Base
    # does — and we honor it). Adapters that don't answer the predicate are assumed
    # synchronous — the conservative default that keeps simple adapters working.
    def validate_block_mode_adapter!(policy)
      return unless policy.block?

      adapter = resolve_adapter_safely(policy.adapter)
      return if adapter.nil? # unknown adapter already raised above

      return unless adapter.respond_to?(:synchronous?)
      return if adapter.synchronous?

      raise ConfigurationError,
        "filter #{policy.class_name}##{policy.field} uses mode :block with the async adapter " \
        "#{policy.adapter.inspect}. :block must reject a save synchronously, which an async adapter " \
        "can't do — use mode: :flag (allow the write, classify in a job, file a Moderate::Flag)."
    end

    # Turn an adapters-registry value into an adapter object. Strings/Classes are
    # constantized and used directly when they expose class-level `classify`
    # (Moderate::Filters::Base style), otherwise instantiated so a host can
    # register a plain class whose instances implement `#classify`.
    def resolve_adapter(ref)
      adapter = case ref
      when String then ref.constantize
      when Class then ref
      else
        return ref
      end

      adapter.respond_to?(:classify) ? adapter : adapter.new
    end

    # Like resolve_adapter but never raises (a built-in whose file isn't loaded yet
    # shouldn't blow up validation) — returns nil if it can't be resolved.
    def resolve_adapter_safely(name)
      adapter_for(name)
    rescue NameError
      nil
    end
  end
end
