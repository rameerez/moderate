# frozen_string_literal: true

require "test_helper"

# Tests for the built-in offline TEXT adapter, Moderate::Filters::Wordlist
# (registered as :wordlist, the default text adapter).
#
# This is the fast offline baseline matcher: a multilingual wordlist
# that emits the gem's canonical taxonomy labels. We test it directly (the class)
# so a failure points straight at the matcher, and also through Moderate.classify
# (the facade) to prove the spine stamps the adapter name onto the Result's source.
#
# Three classic normalization cases anchor the suite:
#   - accent + case insensitive ("PÚT4" -> "puta")            [NFKD + leetspeak]
#   - ordinary content is allowed (no false positive)         [precision]
#   - spaced-out evasion is caught ("p u t a" -> "puta")      [spacing evasion]
# The Spanish "puta" string is deliberate: it exercises the multilingual es.yml
# list AND the accent-fold + leetspeak (4->a) pipeline in a single case — there's
# nothing host-specific about a swear word.
# NOTE: the test class is top-level (not nested under `Moderate::Filters`) on
# purpose. `Moderate::Filters` is an explicit `class` whose subtree Zeitwerk
# autoloads from the `lib/moderate/filters/` directory; opening that namespace just
# to hang a *_test on it would force its autoload at class-definition time and
# couple the test's loadability to Zeitwerk's namespace resolution. References to
# `Moderate::Filters::Wordlist` inside the methods below autoload lazily at call
# time, which is exactly when we want them.
class WordlistFilterTest < ActiveSupport::TestCase
  def classify(value)
    Moderate::Filters::Wordlist.classify(value)
  end

  # --- Allowed path (precision: no false positives) --------------------------

  test "allows ordinary, benign text" do
    result = classify("Running a little late, leaving in five minutes with room to spare.")

    assert result.allowed?
    refute result.flagged?
    assert_empty result.categories
  end

  test "allows blank/empty content without paying for normalization" do
    assert classify("").allowed?
    assert classify("   ").allowed?
    assert classify(nil).allowed?
  end

  # --- Accent + case insensitivity (NFKD fold) -------------------------------

  test "blocks abusive language accent- and case-insensitively (NFKD + leetspeak)" do
    # "  PÚT4  " -> NFKD strips the accent (Ú->u), downcase, leetspeak 4->a -> "put4"
    # -> "puta", which the es.yml harassment list matches. One case that proves
    # accent folding, lowercasing, AND leetspeak transliteration all at once.
    result = classify("  PÚT4  ")

    refute result.allowed?
    assert result.flagged?
    assert_includes result.categories, :harassment
  end

  test "folds accents so an ASCII pattern catches the accented spelling" do
    # es.yml writes "\\bcabr[o0]n\\b" (ASCII) on purpose — the adapter folds accents
    # out BEFORE matching, so the real-world accented "cabrón" still trips.
    result = classify("eres un cabrón")

    refute result.allowed?
    assert_includes result.categories, :harassment
  end

  # --- Leetspeak transliteration ---------------------------------------------

  test "catches leetspeak digit/symbol substitution" do
    # "@ss" -> "ass", "h0le" -> "hole" via the leetspeak map (@->a, 0->o), matching
    # "\\basshole\\b" in en.yml's harassment list.
    result = classify("you are such an @ssh0le")

    refute result.allowed?
    assert_includes result.categories, :harassment
  end

  # --- Spacing / punctuation evasion (compact-form match) --------------------

  test "blocks abusive language split with single spaces" do
    # "p u t a" -> normalized spaced "p u t a", compact "puta" -> matches the
    # trailing-boundary-relaxed compact regex (the spacing-evasion defense).
    result = classify("p u t a")

    refute result.allowed?
    assert_includes result.categories, :harassment
  end

  test "blocks punctuation-as-separator evasion" do
    # "f.u.c.k" -> non-alnum collapse -> "f u c k" -> compact "fuck" -> harassment.
    result = classify("f.u.c.k you")

    refute result.allowed?
    assert_includes result.categories, :harassment
  end

  test "catches a multi-word phrase even when its spaces are removed" do
    # "killyourself" (no spaces) must still match the "kill\\s+yourself" phrase via
    # the compact form, which drops interior whitespace matchers from the pattern.
    result = classify("killyourself")

    refute result.allowed?
    assert_includes result.categories, :"hate/threatening"
  end

  # --- Scunthorpe protection (precision under boundary anchoring) -------------

  test "does not false-positive on a benign word containing a banned substring" do
    # The leading \\b is kept in the compact form precisely so "scunthorpe" (which
    # contains "cunt") does NOT trip — there's no word boundary before "cunt" there.
    result = classify("I grew up in Scunthorpe.")

    assert result.allowed?, "Scunthorpe must not trip the \\bcunt\\b pattern"
  end

  # --- Canonical label mapping + score ---------------------------------------

  test "maps a slash-qualified slug to category + subcategory + input :text" do
    # A hit on the "hate/threatening" YAML key must produce a Label with
    # category :hate, subcategory :threatening, input :text — proving the adapter
    # speaks the canonical taxonomy (not an ad-hoc bucket name).
    result = classify("kys")

    label = result.labels.find { |l| l.category == :hate }
    refute_nil label, "expected a hate label"
    assert_equal :threatening, label.subcategory
    assert_equal :text, label.input
    assert_equal :"hate/threatening", label.slug.to_sym
    assert_includes result.categories, :"hate/threatening"
  end

  test "deterministic match carries score 1.0 (a trip is certain)" do
    # A wordlist has no probability — every matched label is certain (1.0). This is
    # what the Result#scores map and the DSA statement-of-reasons read.
    result = classify("kys")

    result.labels.each { |label| assert_in_delta 1.0, label.score }
    assert_equal({ "hate/threatening" => 1.0 }, result.scores)
  end

  test "records source 'text_filter' to satisfy the flags source constraint" do
    # The wordlist writes Moderate::Flag#source = "text_filter", one of the four
    # values the migration's moderate_flags_source_check constraint allows. (The
    # human-facing adapter NAME, :wordlist, is stamped separately by the spine.)
    result = classify("kys")

    assert_equal "text_filter", result.source
  end

  test "a single value can trip multiple distinct categories" do
    # Mixed content trips more than one canonical category; each appears once.
    result = classify("free crypto, dm whatsapp casino, you bitch")

    assert_includes result.categories, :illicit
    assert_includes result.categories, :harassment
  end

  # --- Multilingual by default (en + es merged) ------------------------------

  test "merges every bundled locale so a Spanish threat is caught too" do
    # The adapter loads and MERGES all bundled blocklists; an English-default app
    # still catches "te voy a matar" (es.yml hate/threatening) with no configuration.
    result = classify("te voy a matar")

    refute result.allowed?
    assert_includes result.categories, :"hate/threatening"
  end

  # --- config.additional_words / config.excluded_words -----------------------

  test "config.additional_words flags a host-specific term as harassment" do
    # A host extends the list without editing the gem. An additional word is bucketed
    # as harassment (the safe generic bucket) on a word-boundary match.
    Moderate.config.additional_words = ["flimflam"]

    result = classify("total flimflam, do not trust them")
    assert result.flagged?
    assert_includes result.categories, :harassment

    # ...and an unrelated benign sentence still passes.
    assert classify("the train was on time today").allowed?
  ensure
    Moderate.config.additional_words = []
  end

  test "config.excluded_words rescues a false positive from the bundled list" do
    # "Scunthorpe" already passes, so use a real residual: exclude a token so an
    # otherwise-tripping word is excised before matching. Here we exclude "bitch"
    # and confirm the same sentence stops tripping harassment via that token.
    flagged = classify("you absolute bitch")
    assert flagged.flagged?, "precondition: the word trips without exclusion"

    Moderate.config.excluded_words = ["bitch"]
    rescued = classify("you absolute bitch")
    refute_includes rescued.categories, :harassment,
      "an excluded word must be excised before matching"
  ensure
    Moderate.config.excluded_words = []
  end

  # --- Sync contract (gates :block eligibility) ------------------------------

  test "is synchronous, so it is valid in :block mode" do
    # :block requires a synchronous adapter (you can't reject a save on a background
    # result). The wordlist declares itself sync via the Base default (async? == false).
    assert Moderate::Filters::Wordlist.synchronous?
    refute Moderate::Filters::Wordlist.async?
  end

  # --- Through the facade (spine stamps the adapter name) ---------------------

  test "Moderate.classify routes to the default wordlist adapter" do
    # End-to-end through the facade: the README's `Moderate.classify("...")` example.
    # The spine resolves config.filter_adapter (:wordlist) and coerces the Result.
    result = Moderate.classify("you bitch")

    refute result.allowed?
    assert_includes result.categories, :harassment
    # The adapter set its own source ("text_filter"); the spine preserves an explicit
    # source rather than overwriting it with the adapter NAME, so the migration's
    # source constraint stays satisfied.
    assert_equal "text_filter", result.source
  end

  test "Moderate.classify returns an allowed Result for benign text" do
    result = Moderate.classify("see you at the meeting point")

    assert result.allowed?
    assert_empty result.categories
  end
end
