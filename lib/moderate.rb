# frozen_string_literal: true

# We lean on a couple of ActiveSupport core extensions (notably String#constantize
# for the lazy class-name resolution that lets `config.user_class = "User"` work
# before the User model is loaded). In a Rails host these are always present; we
# require the specific extension here so the gem also works in a plain-Ruby
# context (a console, a non-Rails test) without booting all of Rails. ActiveSupport
# is a declared runtime dependency in the gemspec.
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/object/blank"

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
require_relative "moderate/engine" if defined?(Rails::Engine)

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
  # Where each of the gem's value lists is labeled for humans, under `moderate.`
  # in I18n. The gem ships English and Spanish for every value it defines
  # (config/locales/*.yml); a host overrides any key in its own locale files (they
  # load after the gem's) and adds the languages it needs. The public DSA notice
  # form has always read the legal_reasons, content_types and member_states keys.
  TAXONOMY_LABEL_SCOPES = {
    category: "categories",              # in-app community report categories (Report#category)
    legal_reason: "legal_reasons",       # DSA statement-of-reasons grounds (Report#legal_reason)
    member_state: "member_states",       # EU member-state codes (Report#legal_country_code)
    content_type: "content_types",       # Report#content_type
    resolution_basis: "resolution_bases", # the Art. 17 ground of a decision (Report#resolution_basis)
    decision: "decisions",               # the restriction imposed (Report#decision_visibility, a decision's :action)
    intake_kind: "intake_kinds",         # community report vs. DSA notice (Report#intake_kind)
    report_status: "statuses.report",
    flag_status: "statuses.flag",
    appeal_status: "statuses.appeal",
    flag_source: "flag_sources",         # Flag#source (host adapter names fall back to humanize)
    flag_mode: "flag_modes",             # Flag#mode
    appeal_source: "appeal_sources"      # Appeal#source
  }.freeze

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
    alias configuration config

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
    #
    # @api private: called by Moderate::Reportable on inclusion.
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

    # --- Reportable field labels ----------------------------------------------

    # The human name of a reported field — what the queue, the statement of
    # reasons, and the appeal page print instead of the raw column name. A
    # moderator reading «Body» on a chat-message report has to guess what was
    # reported; «Chat message» they can act on.
    #
    #   Moderate.reportable_field_label(message, :body)          # => "Chat message"
    #   Moderate.reportable_field_label(Message, "body")         # same, from the class
    #   Moderate.reportable_field_label("Message", "body")       # same, from a stored type
    #
    # Resolution, first non-blank answer wins:
    #
    #   1. the `labels:` declared next to the field
    #      (`has_reportable_content :body, labels: { body: "Chat message" }`) —
    #      a String, or a callable evaluated now (so a lambda can use I18n);
    #   2. i18n `moderate.reportable_fields.<model>.<field>`, where <model> is the
    #      model's `model_name.i18n_key` (`chats/message` for `Chats::Message`),
    #      walking up to STI parents that are themselves reportable;
    #   3. i18n `moderate.reportable_fields.<field>` — one label for every model
    #      that has a field by that name (the gem ships a few generic ones);
    #   4. `field.to_s.humanize`, so an unlabeled field still renders something.
    #
    # Returns nil for a blank field: a whole-record report has no field to name,
    # and callers decide how to say that in their own UI.
    #
    # `record_or_class` may be a record, a class, or a class-name String (a
    # report's `reportable_type`), so a label still resolves after the reported
    # record is gone. An unknown class name skips straight to steps 3–4.
    def reportable_field_label(record_or_class, field)
      field_s = field.to_s.squish
      return if field_s.empty?

      klass, class_name = reportable_label_class(record_or_class)

      translated = reportable_label_i18n_keys(klass, class_name, field_s)
        .lazy.filter_map { |key| reportable_label_i18n(key) }

      declared_reportable_field_label(klass, field_s) || translated.first || field_s.humanize
    end

    # --- Taxonomy labels ------------------------------------------------------

    # The human label for one value of one of the gem's taxonomies, in the current
    # locale — what a report form, a moderation queue or a statement of reasons
    # prints instead of the stored value:
    #
    #   Moderate.taxonomy_label(:category, "harassment")       # => "Harassment"   ("Acoso" in :es)
    #   Moderate.taxonomy_label(:legal_reason, :scams_fraud)   # => "Scams and fraud"
    #   Moderate.taxonomy_label(:flag_status, flag.status)     # => "Awaiting review"
    #
    # Reads `moderate.<scope>.<value>` (TAXONOMY_LABEL_SCOPES), falling back to the
    # value humanized (a member-state code falls back to itself), so a host's own
    # category or adapter name still renders. nil/blank in, nil out. An unknown kind
    # raises: a typo'd kind would otherwise silently print raw values forever.
    def taxonomy_label(kind, value)
      scope = TAXONOMY_LABEL_SCOPES.fetch(kind.to_sym) do
        raise ArgumentError, "unknown taxonomy #{kind.inspect}; one of: #{TAXONOMY_LABEL_SCOPES.keys.join(", ")}"
      end
      value_s = value.to_s.strip
      return if value_s.empty?

      fallback = kind.to_sym == :member_state ? value_s : value_s.tr("/", " ").humanize
      return fallback unless defined?(I18n)

      I18n.t("moderate.#{scope}.#{value_s}", default: fallback)
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
    #
    # @api private: the gem's dispatch into config.notify; hosts wire the hook, they don't call this.
    def notify(event_or_name, **payload)
      event = event_or_name.is_a?(Event) ? event_or_name : Event.new(name: event_or_name, **payload)

      begin
        result = config.notify.call(event)
        # A lambda may legitimately return a delivery handle, a job, true, etc.
        # Anything truthy counts as delivered; nil/false counts as not-delivered.
        result ? true : false
      rescue StandardError => error
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
    #
    # @api private: the gem's dispatch into config.audit.
    def audit(event_or_name = nil, **payload)
      event = event_or_name.is_a?(Event) ? event_or_name : Event.new(name: event_or_name, **payload)
      config.audit.call(event)
      true
    rescue StandardError => error
      logger&.warn("[moderate] audit hook failed for #{event&.name}: #{error.class}: #{error.message}")
      false
    end

    # Run the optional `on_block` side-effect hook (cancel a pending invite, leave a
    # shared room, …). Keyword-arg signature per docs/configuration.md. `at:` is the
    # block row's creation time so hosts can apply time-aware teardown without
    # reaching back into the database. Kept as a facade method so Moderate::Block has
    # one call site and doesn't reach into config internals. No-op by default.
    #
    # @api private: called by Moderate::Block.
    def run_on_block(blocker:, blocked:, at:)
      config.on_block.call(blocker: blocker, blocked: blocked, at: at)
    end

    # Apply a ban via the host's `ban_handler` (suspend!, soft-delete, flip a flag,
    # whatever "banned" means in the host's domain). Keyword-arg signature.
    #
    # Raises ConfigurationError when no ban_handler is wired: auditing and announcing
    # `user_banned` for a ban nothing applied would put a false statement in the
    # audit trail and in the person's inbox.
    #
    # `announce: false` (the decision services) audits now but leaves the
    # `user_banned` notice to the caller: it returns the event's keywords for
    # `Moderate.announce_ban`, so the notice can wait for the decision's commit.
    #
    # @api private: decisions ban through `report.resolve!(ban_user: true)` or
    # `flag.action!(ban_user: true)`, which also send the statement of reasons.
    def apply_ban(user:, by:, reason:, announce: true)
      ensure_ban_handler!
      result = config.ban_handler.call(user: user, by: by, reason: reason)
      payload = {
        user_id: user&.id,
        reason: reason,
        summary: "user #{user&.id || "(unknown)"} banned"
      }.compact
      event = { subject: user, actor: by, recipients: [user].compact, payload: payload }

      audit(:user_banned, **event)
      return event unless announce

      announce_ban(**event)
      result
    end

    # The `user_banned` notice for a ban applied with `apply_ban(announce: false)`.
    #
    # @api private: used by the decision services.
    def announce_ban(**event)
      notify(:user_banned, **event)
    end

    # --- Responsibility -------------------------------------------------------

    # The PERSON responsible for `record` — the account a decision notifies and a
    # ban reaches — or nil when nobody is. It asks the record's `reported_owner`
    # (the Reportable contract) and keeps the answer only if it is an instance of
    # the configured `user_class`.
    #
    # Why the type check lives here: content is often spoken by something that
    # isn't a person — a support desk, a bot, an organization. `chats` answers
    # `author || sender` for a message, which is a desk for an unsigned support
    # reply. Every place moderate stores an owner is a `user_class` association
    # (Report#reported_user, Flag#owner), so a desk there would raise
    # ActiveRecord::AssociationTypeMismatch and take the report down with it.
    # "Nobody to reach" is the honest answer: the report still files, the evidence
    # is still kept, content can still be removed; only a decision notice or a ban
    # has no addressee.
    #
    # A reportable that doesn't define `reported_owner` still raises (loudly, at
    # the first report) — that omission is a bug in the host, not "nobody".
    def responsible_user(record)
      return if record.nil? || !record.respond_to?(:reported_owner)

      owner = record.reported_owner
      owner if owner.is_a?(user_class)
    end

    # Raised before anything changes when a ban is asked for and nothing would apply
    # it. Public so a decision service can check before it takes any lock.
    #
    # @api private: used by the decision services.
    def ensure_ban_handler!
      return true if config.ban_handler_configured?

      raise ConfigurationError,
        "a ban was requested but no config.ban_handler is set, so nothing would suspend the account " \
        "while the audit trail and the statement of reasons said it was. Wire one in " \
        "config/initializers/moderate.rb, e.g. " \
        "`config.ban_handler = ->(user:, by:, reason:) { user.suspend!(reason: reason) }`."
    end

    # --- Transactions -----------------------------------------------------------

    # Hold `record`'s row lock (SELECT … FOR UPDATE) for the block, or just run the
    # block when there's no saved row to lock. The lock is taken by query, not with
    # `record.with_lock`, so the caller's object is neither reloaded nor refused for
    # carrying unsaved changes.
    #
    # THE LOCK ORDER — one, everywhere; a path may skip a step, never reverse two:
    #
    #   flag  →  content  →  person  →  report
    #
    #   - Flag#action!/#dismiss! (ResolveFlag): the flag; to enforce, the content;
    #     to ban, the person; then the report it resolves.
    #   - Report#resolve!/#dismiss! (ResolveReport): the content; to ban, the person;
    #     then the report.
    #   - Flag.flag! / Flag.flag_for_review!: no lock first. The database allows one
    #     pending flag per content + field (the unique pending_key), so they insert,
    #     and only on the collision lock a row: the waiting flag's. Holding no content
    #     lock, they never hold content while waiting on a flag (the inversion against
    #     ResolveFlag); the read of the waiting flag is an equality match on a unique
    #     index, a lock on that one row while it exists.
    #   - "The flag" is, for a pending flag, its pending_key index entry and then its
    #     row (Flag#lock!), the order a colliding insert takes them in on InnoDB.
    #   - The person's lock is taken only when a decision can ban: removal-only
    #     enforcement never waits on, or holds, an account's row.
    #
    # Under the lock, every check that decides "already done" (a covering decision, a
    # prior ban, whether content is gone, the flag waiting after a collision) is
    # itself a LOCKING read (`.lock`, `reload(lock: true)`). Under MySQL's REPEATABLE
    # READ a plain read returns the transaction's snapshot, which may predate the lock,
    # and would miss what the decision we waited for committed; a locking read returns
    # the latest committed row on every database. Those reads come after the locks that serialize them
    # (content, and person for a ban), so two decisions never hold gap locks on the
    # reports table at once.
    #
    # @api private: the lock order the decision services rely on.
    def with_row_lock(record)
      model = record.class
      return yield unless record.respond_to?(:persisted?) && record.persisted? && model.respond_to?(:lock)

      model.transaction do
        model.unscoped.lock.where(model.primary_key => record.id).ids
        yield
      end
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
    # logic lives in exactly one place.
    #
    # ALWAYS a relation selecting user ids (`user_class.where(...).select(:id)`), for
    # a blank user too (then an empty one): compose it into `where.not(user_id: …)`
    # and it stays one subquery. Call `.ids` for an Array of id values. (beta2 gave
    # `[]` for nil and a relation otherwise; a host composing the two got an Array of
    # User records from `relation | array`, and `include?(id)` silently missed.)
    def blocked_ids_for(user)
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
    #
    # @api private: read config.locale.
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

    # Opt-in retention: redact the personal data in reports, flags and appeals whose
    # decision is final and older than `older_than` (default 1 year, never less than
    # the 6-month appeal window), keeping every row and its decision. Nothing calls
    # it unless the host schedules it. See Moderate::Retention and docs/compliance.md.
    #
    #   Moderate.purge(older_than: 1.year)   # => { reports: 12, flags: 40, appeals: 1 }
    def purge(**)
      Retention.purge(**)
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
      @reportable_registry ||= Set.new
    end

    # [Class or nil, class name or nil] for whatever reportable_field_label got.
    def reportable_label_class(record_or_class)
      case record_or_class
      when nil then [nil, nil]
      when Class then [record_or_class, record_or_class.name]
      when String, Symbol
        name = record_or_class.to_s
        [name.safe_constantize, name.presence]
      else
        [record_or_class.class, record_or_class.class.name]
      end
    end

    # A label is display copy, so it must never take a page down: a host lambda
    # that raises is logged and treated as "no declared label" (the i18n/humanize
    # fallbacks still answer), the same way a view should treat a nil.
    def declared_reportable_field_label(klass, field_s)
      return unless klass.respond_to?(:moderation_reportable_field_labels)

      label = klass.moderation_reportable_field_labels[field_s]
      label = label.call if label.respond_to?(:call)
      label.to_s.presence
    rescue StandardError => error
      logger&.warn("[moderate] label for #{klass.name}##{field_s} raised #{error.class}: #{error.message}")
      nil
    end

    # Model-scoped keys first (the class, then its reportable STI parents), then
    # the field-wide key. A class name that no longer constantizes still gets its
    # own model key, derived the way ActiveModel::Name would.
    def reportable_label_i18n_keys(klass, class_name, field_s)
      model_keys =
        if klass
          chain = klass.ancestors.select { |ancestor| ancestor.is_a?(Class) && reportable_label_model?(ancestor) }
          chain = [klass] if chain.empty?
          chain.filter_map { |ancestor| reportable_label_model_key(ancestor) }
        elsif class_name
          [class_name.underscore]
        else
          []
        end

      model_keys.uniq.map { |model_key| "moderate.reportable_fields.#{model_key}.#{field_s}" } +
        ["moderate.reportable_fields.#{field_s}"]
    end

    def reportable_label_model?(klass)
      defined?(Moderate::Reportable) && klass.include?(Moderate::Reportable)
    end

    # `model_name` constantizes the class's namespace, which can raise for a class
    # whose name doesn't match a loaded module; the underscored name is the same
    # key ActiveModel would derive for a non-isolated namespace.
    def reportable_label_model_key(klass)
      return klass.model_name.i18n_key.to_s if klass.respond_to?(:model_name)

      klass.name&.underscore
    rescue NameError
      klass.name&.underscore
    end

    # A translated String, or nil. Two guards: `I18n.t` with no default returns a
    # "Translation missing" string rather than nil, so we ask `exists?` first;
    # and the model-scoped and field-wide keys share one namespace, so a field
    # called `listing` on a host that also has a `Listing` model would read the
    # model's Hash of labels — anything that isn't a String is not a label.
    def reportable_label_i18n(key)
      return unless defined?(I18n) && I18n.exists?(key)

      value = I18n.t(key)
      value.presence if value.is_a?(String)
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
