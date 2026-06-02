# frozen_string_literal: true

module Moderate
  # A single classification label produced by a filter adapter.
  #
  # One piece of content can produce *several* labels — e.g. a message might trip
  # both `hate` and `hate/threatening`, or an image might trip `sexual/minors`
  # while its caption trips `harassment`. Each Label records exactly one
  # (category, subcategory) verdict, the adapter's confidence `score`, and which
  # `input` (text vs image) tripped it. `Moderate::Result` holds the collection.
  #
  # The taxonomy is OpenAI's `omni-moderation-latest` category set, adopted as the
  # gem's ONE canonical vocabulary so every adapter (the offline wordlist, the
  # OpenAI moderation endpoint, or a host-registered backend) speaks the same
  # language — which in turn lets `Moderate::Flag`, the DSA Art. 17 statement of
  # reasons, and the Art. 24 transparency counters all aggregate over a single set.
  # See: https://developers.openai.com/api/docs/guides/moderation
  #
  # Implemented with Ruby's `Data.define` (Ruby 3.2+, which the gemspec requires):
  # an immutable, frozen-by-construction value object — exactly what a label
  # should be (you never mutate a verdict after the fact).
  Label = Data.define(:category, :subcategory, :score, :flagged, :input) do
    # NOTE: constants live OUTSIDE this block (see below). A `Data.define do...end`
    # block is class_eval'd in a context where constant *assignment* leaks to the
    # lexically-enclosing namespace (here `Moderate`) instead of attaching to the
    # Data class — a well-known Ruby gotcha. So `TAXONOMY`/`CATEGORIES`/`INPUTS` are
    # defined by reopening `Moderate::Label` after the `Data.define` call. Instance
    # methods defined in the block (below) are unaffected and work as written.

    # Normalize everything on the way in so adapters can be sloppy about types:
    #   - category/subcategory/input accepted as String or Symbol, downcased
    #   - score coerced to Float (defaults to 1.0 — deterministic adapters like the
    #     wordlist have no probability, so a trip is "certain")
    #   - flagged defaults to true (you only build a Label when something matched)
    def initialize(category:, subcategory: nil, score: 1.0, flagged: true, input: :unknown)
      super(
        category: normalize_symbol(category),
        subcategory: subcategory.nil? ? nil : normalize_symbol(subcategory),
        score: score.nil? ? nil : score.to_f,
        flagged: flagged ? true : false,
        input: normalize_symbol(input || :unknown)
      )
    end

    # The full slug, OpenAI-style: "hate/threatening", "self-harm/intent", or just
    # "hate" when there's no subcategory. This is the canonical wire/storage form
    # used by `Moderate::Result#categories` and persisted on `Moderate::Flag`.
    def slug
      subcategory ? "#{category}/#{subcategory}" : category.to_s
    end

    # True when this label belongs to the canonical taxonomy. Adapters MAY emit
    # off-taxonomy labels (a provider category we haven't mapped) — we don't raise,
    # we just let callers filter on `canonical?` when they want strictness.
    def canonical?
      # `self.class::TAXONOMY` resolves the constant on the Label class regardless
      # of the Data.define block's quirky lexical scope (see the note at the top).
      subs = self.class::TAXONOMY[category]
      return false if subs.nil?

      subcategory.nil? || subs.include?(subcategory)
    end

    private

    def normalize_symbol(value)
      value.to_s.strip.downcase.to_sym
    end
  end

  # --- Canonical taxonomy constants (attached to Moderate::Label) -------------
  # Defined here, by reopening the class, rather than inside the Data.define block
  # above, because constant assignment inside that block would leak to the
  # `Moderate` namespace instead of landing on `Moderate::Label`.
  class Label
    # The canonical OpenAI moderation taxonomy: each top-level category mapped to
    # its allowed subcategories. Sources, in the README and OpenAI's docs
    # (https://developers.openai.com/api/docs/guides/moderation):
    #   harassment      → :threatening
    #   hate            → :threatening
    #   sexual          → :minors
    #   self-harm       → :intent, :instructions
    #   violence        → :graphic
    #   illicit         → :violent
    #
    # `nil` is always an implicitly-valid subcategory (the bare top-level category,
    # e.g. plain `:hate` with no qualifier).
    #
    # NOTE: `self-harm` is the hyphenated symbol `:"self-harm"` to match OpenAI's
    # wire format verbatim — `Result#categories` joins category+subcategory with "/"
    # to reproduce OpenAI's exact slug strings ("self-harm/intent" etc.), so
    # downstream consumers comparing against OpenAI labels line up byte-for-byte.
    TAXONOMY = {
      harassment: %i[threatening],
      hate: %i[threatening],
      sexual: %i[minors],
      "self-harm": %i[intent instructions],
      violence: %i[graphic],
      illicit: %i[violent]
    }.freeze

    # Every canonical category as a flat symbol list, for validation and iteration.
    CATEGORIES = TAXONOMY.keys.freeze

    # Which inputs an adapter can attribute a label to. `:text` and `:image` mirror
    # OpenAI's multimodal `category_applied_input_types`; `:unknown` is the safe
    # default for adapters (like the offline wordlist) that only see one kind of
    # input and don't bother to say which.
    INPUTS = %i[text image unknown].freeze
  end
end
