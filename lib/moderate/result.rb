# frozen_string_literal: true

require_relative "label"

module Moderate
  # The single return type of every filter adapter: `adapter.classify(value) → Moderate::Result`.
  #
  # This is the gem's content-filtering value object — immutable, frozen at
  # construction. It answers the two questions the rest of the gem asks ("is this
  # allowed?" and "if not, why?") and carries the per-label detail for the
  # moderation queue, the DSA statement of reasons, and the transparency counters.
  #
  # The public surface follows the README's "Content filtering" section verbatim:
  #   result.allowed?    # => false
  #   result.flagged?    # => true   (the inverse — convenience for the validator)
  #   result.categories  # => [:hate, :"hate/threatening"]   (canonical slugs)
  #   result.scores      # => { "hate" => 0.97, "hate/threatening" => 0.81 }
  #   result.labels      # => [#<Moderate::Label ...>, ...]
  #   result.source      # => "wordlist" / "openai" / your adapter name
  #   result.raw         # => the untouched provider response (for debugging/audit)
  #
  # Built on `Data.define` (Ruby 3.2+) for a frozen value object. We expose a
  # keyword `.new` whose contract is forgiving: an adapter can hand us either a
  # rich `labels:` array OR the flatter `categories:`/`scores:` shape (the simpler
  # shape a deterministic adapter naturally returns), and we reconcile both into a
  # coherent Result.
  Result = Data.define(:allowed, :labels, :source, :raw) do
    # @param allowed    [Boolean, nil] explicit allow/deny. If nil, we infer it
    #   from whether any label is flagged (no labels ⇒ allowed).
    # @param labels     [Array<Moderate::Label, Hash>] rich per-label verdicts.
    #   Hashes are coerced to `Moderate::Label`. Optional.
    # @param categories [Array<String, Symbol>] flat canonical slugs, the simpler
    #   shape adapters may return instead of `labels:`. Each becomes a Label
    #   (parsing "hate/threatening" → category :hate, subcategory :threatening).
    # @param scores     [Hash] slug => 0..1 score, merged onto the labels built
    #   from `categories:` (and onto label slugs generally).
    # @param source     [String, Symbol] the adapter name that produced this — the
    #   value recorded as `Moderate::Flag#source` so the queue shows which backend
    #   flagged each item. Defaults to "unknown".
    # @param raw        [Object] the untouched provider payload, kept for audit
    #   and debugging. Never relied on by the gem's own logic.
    def initialize(allowed: nil, labels: nil, categories: nil, scores: nil, source: nil, raw: nil)
      scores_hash = normalize_scores(scores)
      built_labels = build_labels(labels, categories, scores_hash)

      # Infer `allowed` when the adapter didn't say: any flagged label ⇒ denied.
      # This lets a deterministic adapter return just `categories: [...]` and have
      # the verdict fall out correctly, without having to compute `allowed` itself.
      resolved_allowed =
        if allowed.nil?
          built_labels.none?(&:flagged)
        else
          allowed ? true : false
        end

      super(
        allowed: resolved_allowed,
        labels: built_labels.freeze,
        source: (source || "unknown").to_s,
        raw: raw
      )
    end

    # Convenience builder for the most common deterministic case: nothing matched.
    def self.allowed(source: nil, raw: nil)
      new(allowed: true, labels: [], source: source, raw: raw)
    end

    def allowed? = allowed

    # The inverse of `allowed?`. The validator and the `moderates` concern read
    # this; it's spelled out (rather than `!allowed`) because "flagged?" is the
    # word everyone reaches for.
    def flagged? = !allowed

    # Canonical category slugs as symbols, e.g. [:hate, :"hate/threatening"].
    # Only flagged labels count — an adapter may return a full score map including
    # non-tripping categories, and those shouldn't show up as "the categories this
    # tripped". De-duplicated, order-preserving.
    def categories
      flagged_labels.map { |label| label.slug.to_sym }.uniq
    end

    # slug => score, e.g. { "hate" => 0.97, "hate/threatening" => 0.81 }. String
    # keys to match OpenAI's wire format and what we persist on the Flag. Skips
    # labels with a nil score (a deterministic adapter may not provide one).
    def scores
      flagged_labels.each_with_object({}) do |label, acc|
        acc[label.slug] = label.score unless label.score.nil?
      end
    end

    private

    def flagged_labels
      labels.select(&:flagged)
    end

    def normalize_scores(scores)
      return {} if scores.nil?

      # Accept symbol- or string-keyed maps; normalize keys to the slug string so
      # we can look up by a Label's slug regardless of how the adapter keyed them.
      scores.each_with_object({}) do |(key, value), acc|
        acc[key.to_s] = value&.to_f
      end
    end

    # Reconcile the two accepted shapes (`labels:` and `categories:`+`scores:`)
    # into one frozen array of `Moderate::Label`.
    def build_labels(labels, categories, scores_hash)
      out = []

      Array(labels).each do |label|
        out << coerce_label(label, scores_hash)
      end

      Array(categories).each do |category|
        out << label_from_slug(category.to_s, scores_hash)
      end

      out
    end

    def coerce_label(label, scores_hash)
      return apply_score(label, scores_hash) if label.is_a?(Moderate::Label)

      # Allow a plain Hash (e.g. from a deserialized adapter response).
      label_from_hash(label.to_h, scores_hash)
    end

    # Backfill a Label's score from the scores map when the Label itself carries
    # none — so an adapter can pass `labels:` for structure and `scores:` for
    # confidence as two parallel inputs.
    def apply_score(label, scores_hash)
      return label unless label.score.nil?

      score = scores_hash[label.slug]
      return label if score.nil?

      Moderate::Label.new(
        category: label.category, subcategory: label.subcategory,
        score: score, flagged: label.flagged, input: label.input
      )
    end

    def label_from_hash(hash, scores_hash)
      hash = hash.transform_keys { |k| k.to_s }
      category = hash["category"]
      subcategory = hash["subcategory"]
      slug = subcategory ? "#{category}/#{subcategory}" : category.to_s

      Moderate::Label.new(
        category: category,
        subcategory: subcategory,
        score: hash.fetch("score", scores_hash[slug]),
        flagged: hash.fetch("flagged", true),
        input: hash.fetch("input", :unknown)
      )
    end

    # Parse a canonical slug ("hate/threatening" or "hate") into a Label, pulling
    # its score from the scores map if present.
    def label_from_slug(slug, scores_hash)
      category, subcategory = slug.split("/", 2)

      Moderate::Label.new(
        category: category,
        subcategory: subcategory,
        score: scores_hash[slug],
        flagged: true,
        input: :unknown
      )
    end
  end
end
