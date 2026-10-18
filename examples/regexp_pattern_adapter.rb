# frozen_string_literal: true

# ──────────────────────────────────────────────────────────────────────────────
# REFERENCE ADAPTER — NOT shipped, NOT loaded, NOT a dependency of `moderate`.
#
# Patterns a word list can't express: phone numbers, links, e-mail addresses,
# "contact me on…" — the off-platform contact and spam shapes a marketplace or a
# chat wants to see. The idea comes from @killondark's PR #1 (2025), written
# against the 0.x validator; this is the same idea in 1.0's adapter contract.
#
# ── How to use it ─────────────────────────────────────────────────────────────
#   1. Copy this file into your app (e.g. app/adapters/regexp_pattern_adapter.rb).
#   2. Register it with your patterns, each under the category it means, and point a
#      field at it. It's synchronous, so :block works as well as :flag:
#          Moderate.configure do |config|
#            config.register_adapter :patterns, RegexpPatternAdapter.new(
#              spam: [%r{https?://}i, /\bwhats\s*app\b/i],
#              privacy: [/\b\d{3}[\s.-]?\d{3}[\s.-]?\d{3}\b/]       # a 9-digit phone number
#            )
#            config.filter "Message", :body, with: :patterns, mode: :flag
#          end
#   3. Categories are yours: any Symbol works. Choose names your queue and your
#      `config.report_categories` already speak (an enforced flag files its report
#      under the first category the community list also has).
#
# ── What it returns ───────────────────────────────────────────────────────────
# A Moderate::Result with one Label per category that matched (score 1.0, input
# :text), `allowed: false` when anything matched, and the matched fragments in
# `raw[:matches]` so the queue can show WHAT tripped it.
# ──────────────────────────────────────────────────────────────────────────────
class RegexpPatternAdapter
  # @param patterns [Hash{Symbol=>Regexp, Array<Regexp>}] category => pattern(s)
  def initialize(patterns = {}, **keyword_patterns)
    @patterns = patterns.to_h.merge(keyword_patterns).to_h do |category, list|
      list = Array(list)
      unless list.all?(Regexp)
        given = list.map(&:class).uniq.join(", ")
        raise ArgumentError, "RegexpPatternAdapter: #{category.inspect} needs Regexp patterns, got #{given}"
      end

      [category.to_sym, list.freeze]
    end.freeze
  end

  # A regexp runs in-process: safe for :block (a validation) as well as :flag.
  def synchronous? = true

  def classify(value)
    matches = matches_in(value.to_s)

    Moderate::Result.new(
      allowed: matches.empty?,
      labels: matches.keys.map { |category| Moderate::Label.new(category: category, score: 1.0, input: :text) },
      source: "patterns",
      raw: { matches: matches }
    )
  end

  private

  # category => the distinct fragments of `text` its patterns matched
  def matches_in(text)
    @patterns.each_with_object({}) do |(category, list), found|
      hits = list.flat_map { |pattern| text.scan(pattern).map { |hit| Array(hit).first.to_s } }.reject(&:empty?)
      found[category] = hits.uniq if hits.any?
    end
  end
end
