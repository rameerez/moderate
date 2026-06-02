# frozen_string_literal: true

require "yaml"
require "set"

module Moderate
  module Filters
    # The default, built-in TEXT adapter: a fast, offline, multilingual,
    # zero-dependency wordlist matcher. It is the ONE built-in adapter the gem ships
    # — registered by the spine under the name :wordlist (config seed
    # "Moderate::Filters::Wordlist", constantized lazily). Synchronous, so it's valid
    # in :block mode.
    #
    # ── What it's for, and what it's NOT ─────────────────────────────────────────
    # This satisfies the store bar of "a method for filtering objectionable UGC
    # before it's posted" (Apple Guideline 1.2:
    # https://developer.apple.com/app-store/review/guidelines/#user-generated-content;
    # Google Play UGC: https://support.google.com/googleplay/android-developer/answer/9876937)
    # with no network call and no external service. It is NOT a full trust-&-safety
    # classifier — it can't read context. For nuance (or for images), register a
    # reference adapter from `examples/` (OpenAI, AWS Rekognition, …) or your own.
    # The bar this clears is "obvious slurs/threats/spam don't sail straight
    # through", at zero latency and zero cost.
    #
    # ── Evasion resistance (the part that matters) ───────────────────────────────
    # Naive substring matching is trivially defeated ("f.u.c.k", "FÜCK", "f u c k",
    # "fuuuck", "fμck"). Before matching, text is NORMALIZED:
    #   1. Unicode NFKD decomposition + stripping combining marks — folds accented
    #      and look-alike forms ("FÜCK" -> "fuck") to a plain base form. NFKD
    #      (compatibility decomposition) also flattens many homoglyph/fullwidth
    #      tricks. (Ruby String#unicode_normalize; \p{Mn} = Unicode "Mark,
    #      nonspacing", the combining accents.)
    #   2. Leetspeak transliteration (0->o, 1->i, 3->e, 4->a, 5->s, 7->t, @->a,
    #      $->s) — folds the common letter/number/symbol swaps.
    #   3. Lowercasing + collapsing every run of non-alphanumerics to a single space
    #      — kills punctuation-as-separator evasion ("f.u.c.k" -> "f u c k").
    # The normalized text is then matched in TWO forms: the single-spaced form
    # (so word-boundary patterns like "\bkill yourself\b" work), AND a space-removed
    # "compact" form (so spacing evasion "f u c k" -> "fuck" is caught). A pattern
    # hits if it matches EITHER form. This is the proven, evasion-resistant
    # matching strategy the adapter relies on.
    #
    # ── Output ───────────────────────────────────────────────────────────────────
    # On a hit, returns a flagged Moderate::Result whose labels are the canonical
    # categories that matched, each with score 1.0 — a deterministic matcher has no
    # probability, so a trip is "certain". `source` is "text_filter" to match the
    # `moderate_flags_source_check` migration constraint.
    class Wordlist < Base
      # NFKD-fold, then strip combining marks. `\p{Mn}` is the Unicode general
      # category "Mark, nonspacing" — the accents that NFKD splits off the base
      # letter. Removing them turns "é" -> "e", "ñ" -> "n", etc.
      COMBINING_MARKS = /\p{Mn}/

      # Common leetspeak / symbol substitutions, folded back to plain letters before
      # matching. Kept tiny on purpose — over-aggressive folding creates false
      # positives (e.g. folding "l"->"i" would mangle ordinary words). These are the
      # high-signal swaps that catch the bulk of leetspeak evasion.
      LEETSPEAK = {
        "0" => "o", "1" => "i", "3" => "e", "4" => "a",
        "5" => "s", "7" => "t", "@" => "a", "$" => "s"
      }.freeze

      # Everything that isn't a-z or 0-9 becomes a single space — collapses
      # punctuation/emoji/whitespace runs into one separator so "f.u.c.k" reads as
      # "f u c k".
      NON_ALNUM = /[^a-z0-9]+/

      # The bundled blocklist YAMLs live in the gem's config dir, one per locale.
      # We load and MERGE all of them (multilingual by default — see es.yml's note).
      BLOCKLISTS_GLOB = File.expand_path("../../../config/moderate/blocklists/*.yml", __dir__)

      # The normalized text, in both matchable forms. A tiny immutable value object
      # so we compute the (mildly expensive) normalization exactly once per classify.
      Normalized = Data.define(:spaced, :compact)

      # The bundled patterns are the same for every classify call and never change
      # at runtime, so compile them ONCE per process and memoize on the class.
      # (config.additional_words / excluded_words are layered in per-call, since the
      # host can in principle reconfigure between calls — and they're cheap.)
      def self.patterns
        @patterns ||= compile_bundled_patterns
      end

      # Reset the compiled-pattern cache. Exposed mainly for the test suite, which
      # may stub the blocklist files; harmless in production.
      def self.reset!
        @patterns = nil
      end

      # Compile every bundled locale file into
      #   { canonical_slug_string => [[spaced_regex, compact_regex], ...] }.
      # Multiple locales contributing the same category (e.g. en + es both add to
      # "harassment") are merged into one pattern list.
      #
      # Each blocklist source string yields TWO compiled regexes, because the matcher
      # tests two normalized forms (see #classify):
      #   - `spaced_regex`  = the source verbatim, with its `\b` word boundaries
      #     intact, tested against the single-spaced form. Boundaries here are what
      #     keep ordinary text from over-matching (the Scunthorpe protection for
      #     normal input).
      #   - `compact_regex` = the source with any TRAILING `\b` removed, tested
      #     against the space-STRIPPED form. This is the spacing-evasion defense:
      #     "f u c k you" normalizes to compact "fuckyou", which a trailing `\b` would
      #     reject (no boundary after "fuck" in "fuckyou"). We keep the LEADING `\b`
      #     so we still anchor to a real word start — that's what stops "scunthorpe"
      #     from matching "\bcunt" (the "cunt" in "scunthorpe" is preceded by "s", so
      #     there's no leading boundary). Dropping only the trailing boundary is the
      #     sweet spot: catches concatenation evasion without opening the Scunthorpe
      #     floodgates. (Genuine residual false positives are handled by
      #     `config.excluded_words`.)
      def self.compile_bundled_patterns
        Dir.glob(BLOCKLISTS_GLOB).each_with_object({}) do |path, acc|
          loaded = YAML.safe_load_file(path) || {}
          loaded.each do |category, raw_patterns|
            list = Array(raw_patterns).map { |source| compile_pair(source) }
            (acc[category.to_s] ||= []).concat(list)
          end
        end
      end

      # Build the [spaced, compact] regex pair for one blocklist source string.
      def self.compile_pair(source)
        spaced = Regexp.new(source)
        compact = Regexp.new(compact_source(source))
        [spaced, compact]
      end

      # Derive the compact-form pattern from a blocklist source. The compact form of
      # the text has ALL whitespace removed, so the pattern must too:
      #   - strip a single trailing `\b` (so single tokens survive concatenation,
      #     e.g. "fuck" inside "fuckyou"); the LEADING `\b` is kept to anchor to a real
      #     word start and keep Scunthorpe-type false positives out;
      #   - drop interior whitespace matchers (`\s+`, `\s*`, and literal spaces) so a
      #     multi-word phrase pattern ("kill\s+yourself") still matches the
      #     space-stripped form ("killyourself") — the no-spaces spelling of the same
      #     evasion.
      def self.compact_source(source)
        source
          .sub(/\\b\z/, "")          # drop trailing word boundary
          .gsub(/\\s[*+]?/, "")      # drop \s, \s*, \s+ whitespace matchers
          .gsub(/\[ ([^\]]*)\]/, '[\1]') # drop a literal space inside a char class
          .delete(" ")               # drop any remaining literal spaces
      end

      def classify(value)
        text = value.to_s
        # Empty / blank content can't violate anything — short-circuit so we don't
        # pay for normalization on the (very common) empty case.
        return allowed_result if text.strip.empty?

        norm = normalize(text)
        hits = matched_categories(norm)

        return allowed_result if hits.empty?

        # One Label per matched canonical slug, score 1.0 (deterministic = certain).
        # `Moderate::Label` parses "hate/threatening" into category :hate +
        # subcategory :threatening for us.
        labels = hits.map do |slug|
          category, subcategory = slug.split("/", 2)
          Moderate::Label.new(
            category: category, subcategory: subcategory,
            score: 1.0, flagged: true, input: :text
          )
        end

        flagged_result(labels: labels)
      end

      private

      # The wordlist writes flags with source "text_filter" — one of the four values
      # allowed by the migration's `moderate_flags_source_check` constraint.
      def source_name
        "text_filter"
      end

      # The canonical slugs that tripped. An excluded word (config.excluded_words)
      # is stripped from the normalized text BEFORE matching, so a legitimate word
      # that contains a banned substring (the classic "Scunthorpe problem") never
      # trips. additional_words are matched as a whole-word extra "harassment" bucket
      # — a host's domain-specific terms it wants caught.
      def matched_categories(norm)
        slugs = self.class.patterns.filter_map do |slug, pairs|
          # A category trips if ANY of its patterns matches EITHER the spaced form
          # (with the precise boundary regex) OR the compact/space-stripped form (with
          # the trailing-boundary-relaxed regex — the spacing-evasion defense).
          slug if pairs.any? { |spaced_re, compact_re| spaced_re.match?(norm.spaced) || compact_re.match?(norm.compact) }
        end

        slugs.concat(additional_word_categories(norm))
        slugs.uniq
      end

      # config.additional_words: extra terms the host wants flagged beyond the
      # bundled lists. We treat a hit on any of them as plain "harassment" (the
      # safest generic bucket for "a word this host disallows") with a word-boundary
      # match on the normalized spaced form. Returns [] when none configured.
      def additional_word_categories(norm)
        words = Array(config.additional_words).map { |w| normalize_token(w) }.reject(&:empty?)
        return [] if words.empty?

        matched = words.any? do |word|
          boundary = /\b#{Regexp.escape(word)}\b/
          boundary.match?(norm.spaced) || norm.compact.include?(word)
        end
        matched ? ["harassment"] : []
      end

      # Full normalization pipeline (see the class header for the why of each step),
      # producing both the single-spaced and space-removed matchable forms. Excluded
      # words are deleted from the spaced form first so they can never contribute a
      # match (and can't bleed into the compact form either).
      def normalize(text)
        folded = fold(text)
        folded = strip_excluded_words(folded)
        Normalized.new(spaced: folded, compact: folded.delete(" "))
      end

      def fold(text)
        text
          .unicode_normalize(:nfkd)
          .downcase
          .gsub(COMBINING_MARKS, "")
          .tr(LEETSPEAK.keys.join, LEETSPEAK.values.join)
          .gsub(NON_ALNUM, " ")
          .strip
          .squeeze(" ") # collapse any residual double spaces (no ActiveSupport #squish dependency)
      end

      # Normalize a single configured token the same way as content, so an
      # excluded/additional word the host writes with caps/accents still lines up
      # with the normalized text it's compared against.
      def normalize_token(word)
        fold(word.to_s).delete(" ")
      end

      # Remove configured false-positive words from the spaced form before matching.
      # We match them on word boundaries so we only excise the standalone word, not
      # every occurrence of the substring.
      def strip_excluded_words(spaced)
        excluded = Array(config.excluded_words).map { |w| normalize_token(w) }.reject(&:empty?)
        return spaced if excluded.empty?

        excluded.reduce(spaced) do |acc, word|
          acc.gsub(/\b#{Regexp.escape(word)}\b/, " ")
        end.squeeze(" ").strip
      end

      def config
        Moderate.config
      end
    end
  end
end
