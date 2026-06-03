# frozen_string_literal: true

require "set"

# We lean on a couple of ActiveSupport core extensions (notably String#constantize
# for the lazy class-name resolution that lets `config.user_class = "User"` work
# before the User model is loaded). In a Rails host these are always present; we
# require the specific extension here so the gem also works in a plain-Ruby
# context (a console, a non-Rails test) without booting all of Rails. ActiveSupport
# is a declared runtime dependency in the gemspec.
require "active_support/core_ext/string/inflections"

require_relative "moderate/version"
require_relative "moderate/errors"
require_relative "moderate/label"
require_relative "moderate/result"
require_relative "moderate/event"
require_relative "moderate/configuration"

# The class-level DSL (has_reporting_and_blocking / has_reportable_content / moderates). Required here,
# eagerly, because the engine's `moderate.active_record` initializer does
# `extend Moderate::Macros` inside an `on_load(:active_record)` block — the constant
# must already be defined by the time that hook fires. It's a plain module that only
# references the (autoloaded) concern constants inside its method BODIES, so loading
# it at gem-require time is cheap and order-independent. It is also in the engine's
# Zeitwerk ignore-list precisely so this manual require is the single load path.
require_relative "moderate/macros"

# The engine wires the gem into a Rails host: it teaches Zeitwerk to autoload the
# AR models / concerns / services / jobs / adapters under `lib/moderate/*`, mounts
# the public DSA notice form, and registers the macros on ActiveRecord. Required
# only when Rails is present so the value objects + macros above can still be used
# in a plain-Ruby context (a console, a non-Rails script) without booting an engine.
require_relative "moderate/engine" if defined?(::Rails::Engine)

# `moderate` — a complete Trust & Safety layer for Rails apps with user-generated
# content: report, block, filter, moderate, appeal, comply (EU DSA / Apple App
# Store Guideline 1.2 / Google Play UGC).
#
# This file is the SPINE: the `Moderate` module and its facade. Everything else in
# the gem imports from here. The facade is deliberately small — it owns
# configuration, lazy identity resolution, the notify/audit hook dispatch, the
# blocked-ids source-of-truth delegate, and the content-classification entry point.
# The heavy lifting (the AR models, the decision services, the controllers) lives
# in the autoloaded `app/` tree and calls back into these facade methods.
module Moderate
  class << self
    # --- Configuration --------------------------------------------------------

    # The singleton Configuration. Lazily built so merely requiring the gem (before
    # any initializer runs) yields a fully-defaulted, usable config.
    def config
      @config ||= Configuration.new
    end

    # Read alias. Some ecosystem gems expose `.configuration`; we keep `.config`
    # as the canonical name (matches the README's `Moderate.config`) and provide
    # `.configuration` only as a courtesy alias for muscle memory.
    alias_method :configuration, :config

    # The host's entry point: `Moderate.configure do |config| ... end`.
    #
    # We `yield` the live config object (so every assignment lands on the singleton)
    # and then run `validate!` ONCE at the end — this is the documented behavior in
    # docs/configuration.md: "The block is validated at the end of `configure`, so a
    # typo'd mode or unknown adapter raises a plain-English ArgumentError
    # immediately instead of failing mysteriously later." Per-setter checks already
    # fired on assignment; this final pass catches cross-field problems (e.g. a
    # :block filter on an async adapter).
    def configure
      yield config if block_given?
      config.validate!
      config
    end

    # Reset to a pristine, fully-defaulted Configuration. The primary consumer is
    # the test suite (`Moderate.reset!` between cases); it's documented as part of
    # the public API. We also drop the cached user-class constant so a test that
    # swaps `config.user_class` doesn't see a stale lazily-memoized class.
    #
    # IMPORTANT: we do NOT clear the reportable REGISTRY here. Reportable classes are
    # discovered once, at MODEL LOAD time (the `has_reportable_content` macro / `include
    # Moderate::Reportable` runs `Moderate.register_reportable(self)` on inclusion).
    # In a booted app (and the eager-loaded test suite) the models load exactly once,
    # so wiping the registry on every `reset!` would leave `Moderate.reportable_classes`
    # permanently empty after the first reset — the macros would never re-run to
    # repopulate it. The registry is a load-time FACT, not configuration, so it
    # correctly survives a config reset.
    def reset!
      @config = Configuration.new
      @user_class = nil
      self
    end

    # --- Identity -------------------------------------------------------------

    # The actor model (who reports/blocks/gets reported/gets banned), resolved by
    # constantizing `config.user_class` LAZILY on first use. Lazy on purpose: the
    # initializer that sets `config.user_class = "User"` runs before the User model
    # is necessarily loaded, so we must not constantize at configure time.
    #
    # Memoized, but cleared by `reset!` and re-derived if the configured name
    # changes (guards against a stale constant in long-lived processes/tests).
    def user_class
      name = config.user_class
      if @user_class.nil? || @user_class_name != name
        @user_class = name.constantize
        @user_class_name = name
      end
      @user_class
    end

    # --- Reportable registry --------------------------------------------------

    # Auto-discovered set of classes that declared themselves reportable (via the
    # `has_reportable_content` macro or `include Moderate::Reportable`). The Reportable concern
    # calls `Moderate.register_reportable(self)` on inclusion, so there's NO manual
    # registry to maintain — exactly what the README promises ("Reportable classes
    # are auto-discovered from the `has_reportable_content` macro — no manual registry.").
    #
    # Stored as a Set of STRING class names (not Class objects) so we never pin a
    # class in memory across a Zeitwerk reload in development; we constantize on read.
    def register_reportable(klass)
      name = klass.is_a?(Class) ? klass.name : klass.to_s
      return if name.nil? || name.empty?

      reportable_registry << name
      name
    end

    # The reportable classes, constantized on demand. We rescue a NameError per
    # entry so a class that was registered then removed (a dev-time edit) doesn't
    # break the whole list.
    def reportable_classes
      reportable_registry.filter_map do |name|
        name.constantize
      rescue NameError
        nil
      end
    end

    # --- Notify / audit hooks -------------------------------------------------

    # Dispatch a notifiable moment to the host's `config.notify` hook.
    #
    # Accepts either a ready-made Moderate::Event or an event NAME plus payload —
    # the gem's services mostly call `Moderate.notify(:report_received, subject:,
    # recipients:, ...)`, but a pre-built Event is accepted too. We always hand the
    # hook a Moderate::Event so the host's single `case event.name` works uniformly.
    #
    # RETURNS a "delivered" boolean. This exists specifically for legal-email
    # gating: DSA Art. 16(4) requires a confirmation of receipt for a notice, and
    # the notice flow needs to know whether the confirmation actually went out so
    # it can fall back (e.g. show an on-screen receipt) if the host hasn't wired a
    # mailer. "Delivered" means the hook ran without raising and returned a truthy
    # value — the default no-op hook returns nil ⇒ false, which correctly signals
    # "nothing was sent."
    #
    # We never let a host hook's exception bubble into a moderation action (a slow
    # or broken mailer must not roll back a decision). On error we audit the failure
    # and return false.
    def notify(event_or_name, **payload)
      event = event_or_name.is_a?(Event) ? event_or_name : Event.new(name: event_or_name, **payload)

      begin
        result = config.notify.call(event)
        # A lambda may legitimately return a delivery handle, a job, true, etc.
        # Anything truthy counts as delivered; nil/false counts as not-delivered.
        result ? true : false
      rescue => error
        audit(
          name: :notify_failed,
          subject: event.subject,
          payload: {
            event: event.name,
            error_class: error.class.name,
            error_message: error.message,
            summary: "notify hook failed for #{event.name}: #{error.class}"
          }
        )
        false
      end
    end

    # Dispatch an auditable moment to the host's `config.audit` hook (no-op by
    # default). Same Event envelope as notify, so a host can point both hooks at the
    # same `case`. Like notify, an audit hook exception is swallowed (turned into a
    # logged warning) so it can never roll back the action it's recording — audit is
    # observational, never load-bearing.
    def audit(event_or_name = nil, **payload)
      event = event_or_name.is_a?(Event) ? event_or_name : Event.new(name: event_or_name, **payload)
      config.audit.call(event)
      true
    rescue => error
      logger&.warn("[moderate] audit hook failed for #{event&.name}: #{error.class}: #{error.message}")
      false
    end

    # Run the optional `on_block` side-effect hook (cancel a pending invite, leave a
    # shared room, …). Keyword-arg signature per docs/configuration.md. `at:` is the
    # block row's creation time so hosts can apply time-aware teardown without
    # reaching back into the database. Kept as a facade method so Moderate::Block has
    # one call site and doesn't reach into config internals. No-op by default.
    def run_on_block(blocker:, blocked:, at:)
      config.on_block.call(blocker: blocker, blocked: blocked, at: at)
    end

    # Apply a ban via the host's `ban_handler` (suspend!, soft-delete, flip a flag,
    # whatever "banned" means in the host's domain). Keyword-arg signature. No-op by
    # default — the surrounding decision still audits and notifies even if no ban is
    # wired, so the action is never silently dropped (docs/configuration.md).
    def apply_ban(user:, by:, reason:)
      result = config.ban_handler.call(user: user, by: by, reason: reason)
      payload = {
        user_id: user&.id,
        reason: reason,
        summary: "user #{user&.id || '(unknown)'} banned"
      }.compact

      audit(:user_banned, subject: user, actor: by, recipients: [user].compact, payload: payload)
      notify(:user_banned, subject: user, actor: by, recipients: [user].compact, payload: payload)
      result
    end

    # --- Blocking SSOT --------------------------------------------------------

    # The single source-of-truth list of user ids "related to" `user` via a block
    # edge — i.e. everyone this user has blocked AND everyone who has blocked them
    # (the edge is bidirectional; once either side blocks, neither should see the
    # other). The host enforces blocking everywhere with one query:
    #
    #   Post.where.not(user_id: Moderate.blocked_ids_for(current_user))
    #
    # Delegates to Moderate::Block (the model that owns the block SQL) so the join
    # logic lives in exactly one place. Returns an empty array for a blank user.
    def blocked_ids_for(user)
      return [] if user.nil?

      Block.related_user_ids(user)
    end

    # --- Content classification ----------------------------------------------

    # Classify a value (text or image) and return a Moderate::Result.
    #
    #   Moderate.classify("some sketchy text")           # uses the default adapter
    #   Moderate.classify(value, policy: some_policy)    # uses the policy's adapter
    #
    # Adapter selection precedence:
    #   1. the adapter named on the passed `policy` (per-field config / `moderates`)
    #   2. the global `config.filter_adapter` default
    #
    # The adapter contract is the whole point of the gem's filtering design: ANY
    # object responding to `classify(value) → Moderate::Result` is a valid adapter,
    # so the built-in wordlist/image backends and a host's registered remote
    # classifier are perfectly interchangeable. We tolerate an adapter that returns
    # a plain Hash (a common simpler shape) by funneling it through Result.new, so
    # older/simpler adapters keep working.
    def classify(value, policy: nil)
      adapter_name = policy&.adapter || config.filter_adapter
      adapter = config.adapter_for(adapter_name)

      raise ConfigurationError, "no filter adapter registered for #{adapter_name.inspect}" if adapter.nil?

      raw = adapter.classify(value)
      coerce_result(raw, source: adapter_name)
    end

    # Resolve the FilterPolicy for a given record/class + field, walking the
    # ancestor chain so a policy declared on a base/STI parent applies to subclasses
    # (this is why a marketplace's `Listing` policy covers `Listing::Featured`, etc.
    # — host-agnostically). Falls back to an `:off` policy when nothing is declared,
    # so callers can treat "no policy" and ":off" identically.
    def filter_policy_for(record_or_class, field)
      klass = record_or_class.is_a?(Class) ? record_or_class : record_or_class.class
      field_s = field.to_s

      policy = klass.ancestors.filter_map do |ancestor|
        next unless ancestor.respond_to?(:name) && ancestor.name

        config.filters[[ancestor.name, field_s]]
      end.first

      policy || Configuration::FilterPolicy.new(
        class_name: klass.name, field: field_s, adapter: config.filter_adapter, mode: :off
      )
    end

    # Register a filter adapter at runtime (the facade twin of
    # `config.register_adapter`, so a host can call either
    # `Moderate.register_adapter(...)` or `config.register_adapter(...)`).
    def register_adapter(name, adapter)
      config.register_adapter(name, adapter)
    end

    # The locale for copy the gem generates itself, falling back to the app's
    # default. Read lazily so a host setting I18n.default_locale after our boot
    # still wins.
    def locale
      config.locale || (defined?(I18n) ? I18n.default_locale : :en)
    end

    # DSA Art. 24 transparency aggregation for a period — the numbers a host
    # publishes (notices received by intake/ground, actions taken, automated-means
    # usage, appeal outcomes, median handling times). This is the queryable building
    # block: the public `/transparency` page (off by default — see
    # `config.transparency_report_enabled`) renders this, and a host that keeps the
    # page off can still call this to publish its own report in its own format.
    def transparency(from: nil, to: nil)
      to ||= Time.respond_to?(:current) ? Time.current : Time.now
      from ||= to - (365 * 24 * 60 * 60)
      reports = Moderate::Report.where(created_at: from..to)
      appeals = Moderate::Appeal.where(created_at: from..to)
      flags = Moderate::Flag.where(created_at: from..to)

      {
        period: { from: from, to: to },
        notices_by_intake: reports.group(:intake_kind).count,
        dsa_notices_by_legal_reason: reports.where(intake_kind: "dsa").group(:legal_reason).count,
        actions_by_basis: reports.where.not(resolved_at: nil).group(:resolution_basis).count,
        automated_flags_by_source: flags.group(:source).count,
        appeals_by_status: appeals.group(:status).count,
        median_notice_action_seconds: transparency_median(reports.where.not(resolved_at: nil).pluck(:created_at, :resolved_at)),
        median_appeal_action_seconds: transparency_median(appeals.where.not(resolved_at: nil).pluck(:created_at, :resolved_at))
      }
    end

    private

    # Median seconds between paired (created_at, resolved_at) timestamps; 0 when empty.
    def transparency_median(pairs)
      values = pairs.filter_map { |created_at, resolved_at| resolved_at && created_at ? (resolved_at - created_at).to_i : nil }.sort
      return 0 if values.empty?

      values[values.length / 2]
    end

    # The internal reportable-name set. Set (not Array) so re-including the concern
    # is idempotent.
    def reportable_registry
      @reportable_classes ||= Set.new
    end

    # Coerce whatever an adapter returned into a Moderate::Result, stamping the
    # adapter NAME as the result's `source` when the adapter didn't set one — this
    # is what makes `Moderate::Flag#source` show which backend flagged an item, so
    # the moderation queue is legible. An adapter that DID set an explicit source
    # keeps it (we only backfill the "unknown" default). A Hash is funneled through
    # Result.new (back-compat with the reference `{ allowed:, categories:, scores:,
    # source:, raw: }` shape).
    def coerce_result(raw, source:)
      if raw.is_a?(Result)
        return raw unless raw.source == "unknown"

        return Result.new(allowed: raw.allowed?, labels: raw.labels, source: source.to_s, raw: raw.raw)
      end

      if raw.respond_to?(:to_h)
        hash = raw.to_h.transform_keys(&:to_sym)
        return Result.new(
          allowed: hash[:allowed],
          labels: hash[:labels],
          categories: hash[:categories],
          scores: hash[:scores],
          source: hash[:source] || source,
          # Tolerate the reference adapters' `:metadata` key as `raw` for audit.
          raw: hash[:raw] || hash[:metadata]
        )
      end

      # An adapter returning something opaque (truthy ⇒ allowed) — defensive only.
      Result.new(allowed: raw ? true : false, source: source, raw: raw)
    end

    def logger
      return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      nil
    end
  end
end
