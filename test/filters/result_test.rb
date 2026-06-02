# frozen_string_literal: true

require "test_helper"

# Tests for the two filtering VALUE OBJECTS the adapter contract revolves around:
# `Moderate::Result` (the single return type of every `adapter.classify(value)`)
# and `Moderate::Label` (one (category, subcategory) verdict).
#
# These are pure, frozen `Data.define` objects with no AR / Rails dependency — but
# we run them under ActiveSupport::TestCase anyway (via test_helper) so the whole
# `test/filters` directory boots the same way and `Moderate.reset!`/`configure`
# isolation from the shared setup applies uniformly. Nothing here touches the DB.
#
# The behaviour under test is the README's "Content filtering" contract verbatim:
#   result.allowed? / result.flagged?
#   result.categories  # => [:hate, :"hate/threatening"]
#   result.scores      # => { "hate" => 0.97, "hate/threatening" => 0.81 }
#   result.labels      # => [#<Moderate::Label ...>, ...]
class Moderate::ResultTest < ActiveSupport::TestCase
  # --- Label -----------------------------------------------------------------

  test "Label#slug joins category and subcategory OpenAI-style, or bare category" do
    # The slug is the canonical wire/storage form persisted on Moderate::Flag and
    # read by Result#categories. With a subcategory it's "category/subcategory";
    # without one it's just the bare category. See the OpenAI taxonomy this mirrors:
    # https://developers.openai.com/api/docs/guides/moderation
    qualified = Moderate::Label.new(category: :hate, subcategory: :threatening)
    bare = Moderate::Label.new(category: :hate)

    assert_equal "hate/threatening", qualified.slug
    assert_equal "hate", bare.slug
  end

  test "Label normalizes string/symbol/mixed-case inputs to downcased symbols" do
    # Adapters may be sloppy about types (a YAML-loaded slug is a String, OpenAI's
    # wire keys are Strings, a host adapter might pass Symbols). The Label normalizes
    # everything to a downcased Symbol so the rest of the gem compares apples to
    # apples regardless of how the adapter expressed it.
    label = Moderate::Label.new(category: "HATE", subcategory: "Threatening", input: "TEXT")

    assert_equal :hate, label.category
    assert_equal :threatening, label.subcategory
    assert_equal :text, label.input
  end

  test "Label score defaults to 1.0 (deterministic = certain) and coerces to Float" do
    # A deterministic matcher (the wordlist) has no probability — a trip is certain,
    # so the score defaults to 1.0. A provider score is coerced to Float so callers
    # never have to guard against an Integer/String slipping through.
    assert_in_delta 1.0, Moderate::Label.new(category: :hate).score
    assert_in_delta 0.5, Moderate::Label.new(category: :hate, score: "0.5").score
  end

  test "Label#flagged? defaults true and coerces truthiness" do
    # You only build a Label when something matched, so flagged defaults to true.
    assert Moderate::Label.new(category: :hate).flagged
    refute Moderate::Label.new(category: :hate, flagged: false).flagged
  end

  test "Label#canonical? distinguishes taxonomy members from off-taxonomy labels" do
    # Adapters MAY emit a provider category we haven't mapped; the gem doesn't raise,
    # but callers can filter on canonical?. A bare category, a valid subcategory, an
    # unknown category, and an unknown subcategory must all answer correctly.
    assert Moderate::Label.new(category: :hate).canonical?
    assert Moderate::Label.new(category: :hate, subcategory: :threatening).canonical?
    refute Moderate::Label.new(category: :nonsense).canonical?
    refute Moderate::Label.new(category: :hate, subcategory: :nonsense).canonical?
  end

  test "Label taxonomy constants match the canonical OpenAI category set" do
    # Pin the canonical vocabulary so an accidental rename of a category breaks here
    # loudly rather than silently diverging from OpenAI's wire labels (which the
    # OpenAI adapter, the wordlist YAMLs, and the DSA counters all key off).
    assert_equal %i[harassment hate sexual self-harm violence illicit].sort,
                 Moderate::Label::CATEGORIES.sort
    assert_equal %i[intent instructions], Moderate::Label::TAXONOMY[:"self-harm"]
    assert_includes Moderate::Label::INPUTS, :text
    assert_includes Moderate::Label::INPUTS, :image
  end

  # --- Result: the rich `labels:` shape --------------------------------------

  test "Result built from labels exposes allowed?/flagged?/categories/scores/labels" do
    # The full happy-path of a service adapter: it hands a list of rich Labels and an
    # explicit allowed:false, and the Result projects the README's read surface.
    result = Moderate::Result.new(
      allowed: false,
      labels: [
        Moderate::Label.new(category: :hate, score: 0.97),
        Moderate::Label.new(category: :hate, subcategory: :threatening, score: 0.81)
      ],
      source: "openai"
    )

    refute result.allowed?
    assert result.flagged?
    assert_equal [:hate, :"hate/threatening"], result.categories
    assert_equal({ "hate" => 0.97, "hate/threatening" => 0.81 }, result.scores)
    assert_equal "openai", result.source
    assert_equal 2, result.labels.size
  end

  test "Result.allowed builds the canonical nothing-matched verdict" do
    result = Moderate::Result.allowed(source: "wordlist")

    assert result.allowed?
    refute result.flagged?
    assert_empty result.categories
    assert_empty result.scores
    assert_empty result.labels
    assert_equal "wordlist", result.source
  end

  # --- Result: the flat `categories:` + `scores:` shape ----------------------

  test "Result built from flat categories+scores parses slugs and infers denial" do
    # A deterministic adapter may return the simpler `categories:`/`scores:` shape
    # instead of rich labels. The Result must parse "hate/threatening" into a
    # category+subcategory Label, attach the matching score, AND — crucially — INFER
    # allowed:false because a flagged label is present (no explicit allowed: given).
    result = Moderate::Result.new(
      categories: ["hate", "hate/threatening"],
      scores: { "hate" => 0.97, "hate/threatening" => 0.81 }
    )

    refute result.allowed?, "a flagged label must make the result deny by inference"
    assert_equal [:hate, :"hate/threatening"], result.categories
    assert_equal({ "hate" => 0.97, "hate/threatening" => 0.81 }, result.scores)

    threatening = result.labels.find { |label| label.subcategory == :threatening }
    assert_equal :hate, threatening.category
    assert_in_delta 0.81, threatening.score
  end

  test "Result with no labels and no explicit verdict infers allowed" do
    # The inverse inference: nothing flagged ⇒ allowed. This is what lets a
    # deterministic adapter return an empty Result and have the verdict fall out.
    result = Moderate::Result.new

    assert result.allowed?
    refute result.flagged?
  end

  test "Result#categories de-duplicates and counts only flagged labels" do
    # An adapter may return a full score map including non-tripping categories; those
    # must NOT appear in `categories` (which means "what this tripped"), and a repeated
    # slug must collapse to one entry, order preserved.
    result = Moderate::Result.new(
      allowed: false,
      labels: [
        Moderate::Label.new(category: :hate, flagged: true),
        Moderate::Label.new(category: :hate, flagged: true),    # dup
        Moderate::Label.new(category: :sexual, flagged: false)  # scored but not flagged
      ]
    )

    assert_equal [:hate], result.categories
  end

  test "Result#scores skips labels with a nil score" do
    # A deterministic adapter may flag with no probability; the scores map should
    # simply omit those rather than emit a nil value the persistence layer would choke on.
    result = Moderate::Result.new(
      allowed: false,
      labels: [Moderate::Label.new(category: :hate, score: nil)]
    )

    assert_equal [:hate], result.categories
    assert_empty result.scores
  end

  test "Result backfills a label's score from a parallel scores map" do
    # An adapter can pass structure via `labels:` and confidence via a parallel
    # `scores:` map keyed by slug; the Result reconciles the two onto each Label.
    result = Moderate::Result.new(
      allowed: false,
      labels: [Moderate::Label.new(category: :hate, subcategory: :threatening, score: nil)],
      scores: { "hate/threatening" => 0.42 }
    )

    assert_in_delta 0.42, result.labels.first.score
    assert_equal({ "hate/threatening" => 0.42 }, result.scores)
  end

  test "Result accepts plain-Hash labels (deserialized adapter response)" do
    # Back-compat: an adapter that returns Hash labels (e.g. from a JSON round-trip)
    # is coerced into Moderate::Label. Symbol- or string-keyed both work.
    result = Moderate::Result.new(
      allowed: false,
      labels: [{ "category" => "sexual", "subcategory" => "minors", "score" => 0.9, "input" => "image" }]
    )

    label = result.labels.first
    assert_equal :sexual, label.category
    assert_equal :minors, label.subcategory
    assert_equal :image, label.input
    assert_equal [:"sexual/minors"], result.categories
  end

  test "Result normalizes symbol-keyed scores to string slugs" do
    # Adapters may key scores with Symbols; the Result normalizes to the string slug
    # so a Label lookup by slug works regardless of how the adapter keyed the map.
    result = Moderate::Result.new(categories: [:hate], scores: { hate: 0.6 })

    assert_equal({ "hate" => 0.6 }, result.scores)
  end

  test "Result defaults source to unknown and keeps the raw payload untouched" do
    payload = { "provider" => "stub", "flagged" => true }
    result = Moderate::Result.new(allowed: false, labels: [Moderate::Label.new(category: :hate)], raw: payload)

    assert_equal "unknown", result.source
    assert_same payload, result.raw
  end

  test "Result is frozen and immutable" do
    # Data.define gives us value-object immutability; assert it so a refactor that
    # accidentally introduces mutation fails loudly.
    result = Moderate::Result.allowed(source: "wordlist")

    assert result.frozen?
    assert result.labels.frozen?
  end
end
