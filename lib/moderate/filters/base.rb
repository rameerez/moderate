# frozen_string_literal: true

module Moderate
  # The built-in filter adapters live under `Moderate::Filters`. They're the
  # gem's own implementations of the ONE adapter contract the whole filtering
  # design hinges on:
  #
  #     adapter.classify(value) -> Moderate::Result
  #
  # ...where `value` is a piece of user content (a String of text, or an image
  # reference) and the returned `Moderate::Result` answers "is this allowed?" and,
  # if not, "why?" (the per-`Moderate::Label` detail, mapped onto the gem's single
  # canonical taxonomy — see `Moderate::Label`).
  #
  # ── How adapters are invoked ────────────────────────────────────────────────
  # The configuration registry (`Moderate::Configuration#adapters`) stores each
  # adapter as EITHER a live object the host registered, OR a class-NAME String the
  # gem constantizes lazily. The two built-ins are seeded as the strings
  # "Moderate::Adapters::Wordlist" / "Moderate::Adapters::Image", and
  # `Configuration#resolve_adapter` returns the CLASS itself for a String/Class
  # entry. That means the gem calls `SomeAdapterClass.classify(value)` and
  # `SomeAdapterClass.synchronous?` — i.e. the built-ins expose CLASS methods, not
  # instance methods. (A host's own adapter registered as an instance exposes the
  # same `#classify`/`#synchronous?` on that instance — same duck type, both work.)
  #
  # `Base` gives the built-ins both halves of that duck type from a single source:
  # subclasses implement the work as an INSTANCE method (`#classify`), and `Base`
  # provides the CLASS-level `classify`/`synchronous?`/`async?` that the registry
  # resolution path calls, delegating the class call to a fresh instance. So one
  # implementation satisfies both call styles and there's no copy-paste.
  #
  # ── Sync vs. async (why it matters for :block) ──────────────────────────────
  # `Configuration#validate!` enforces the README's rule: a `:block`-mode filter
  # MUST use a synchronous adapter, because you can't reject a save on a result
  # that's still computing in a background job. The validator probes the adapter
  # with `synchronous?` and treats anything that doesn't answer, or answers truthy,
  # as synchronous (the safe default that keeps simple adapters working); only an
  # adapter that explicitly returns `synchronous? == false` is rejected for :block.
  #
  # We model this once here as `async?` (default `false` — built-ins are sync) and
  # derive `synchronous?` from it, so a subclass flips ONE flag
  # (`def self.async? = true`) to declare itself background-only. The OpenAI adapter
  # does exactly that; the wordlist and image adapters leave the default.
  module Filters
    class Base
      class << self
        # The class-level entry point the registry resolution path calls. Spins up
        # a per-call instance so subclasses can keep per-classification state in
        # instance vars without any thread-safety worry (a new instance per call).
        def classify(value)
          new.classify(value)
        end

        # Is this adapter background-only? Default `false` — the built-in
        # deterministic adapters run inline. Override with `def self.async? = true`
        # in an adapter whose `classify` does blocking I/O (a network moderation
        # API), so the gem routes it through `Moderate::ClassifyJob` in :flag mode
        # and forbids it in :block mode.
        def async?
          false
        end

        # The predicate the spine's `Configuration#validate_block_mode_adapter!`
        # actually reads. Defined in terms of `async?` so there's a single source
        # of truth: an async adapter is, by definition, not synchronous.
        def synchronous?
          !async?
        end
      end

      # Subclasses MUST implement `#classify(value) -> Moderate::Result`. We raise a
      # clear NotImplementedError rather than silently allowing nil, so a half-built
      # adapter fails loudly in development instead of mysteriously "allowing"
      # everything in production.
      def classify(_value)
        raise NotImplementedError, "#{self.class} must implement #classify(value) and return a Moderate::Result"
      end

      private

      # Mirror the class-level predicates on the instance, so a `Base` subclass
      # registered as an *instance* (rather than resolved from a class name) still
      # answers the same duck type the validator probes.
      def async?
        self.class.async?
      end

      def synchronous?
        self.class.synchronous?
      end

      # ── Shared helpers for subclasses ────────────────────────────────────────

      # The canonical "nothing matched" Result, stamped with this adapter's name so
      # an allowed verdict is still attributable in audit. Adapters call this on the
      # happy path (and, for the network adapter, on a fail-open error path — see
      # the OpenAI adapter's rescue, which must NEVER block a save on a transient
      # network blip).
      def allowed_result(raw: nil)
        Moderate::Result.allowed(source: source_name, raw: raw)
      end

      # Build a flagged Result from a list of canonical label hashes/objects. Thin
      # wrapper so subclasses don't repeat the `source:`/`allowed:` bookkeeping.
      def flagged_result(labels:, raw: nil)
        Moderate::Result.new(allowed: false, labels: labels, source: source_name, raw: raw)
      end

      # The adapter's `source` string — the value recorded on `Moderate::Flag#source`
      # so the moderation queue shows which backend flagged each item. Defaults to
      # the demodulized, underscored class name ("Wordlist" -> "wordlist"); the
      # built-ins override it to the migration's allowed `source` enum values
      # ("text_filter" / "image_filter" / "external_classifier"). See the
      # `moderate_flags_source_check` constraint in the install migration.
      def source_name
        self.class.name.to_s.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
