# frozen_string_literal: true

# ──────────────────────────────────────────────────────────────────────────────
# REFERENCE ADAPTER — NOT shipped, NOT loaded, NOT a dependency of `moderate`.
#
# `moderate` ships exactly ONE built-in adapter: the offline `:wordlist`. Every
# other backend — including this OpenAI one — is "bring your own": you copy this
# file into your app, add its gem to YOUR Gemfile, and register it yourself. The
# gem deliberately has no `ruby_llm`/`openai`/HTTP dependency, so nothing here is
# pulled into a host that doesn't want it.
#
# ── How to use it ─────────────────────────────────────────────────────────────
#   1. Copy this file into your app (e.g. app/adapters/openai_moderation_adapter.rb).
#   2. Add the runtime dependency to YOUR app's Gemfile:
#          gem "ruby_llm"
#      and configure your key (https://github.com/crmne/ruby_llm):
#          RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
#   3. Register the adapter and point a field at it, in :flag mode:
#          Moderate.configure do |config|
#            config.register_adapter(:openai, OpenAIModerationAdapter.new)
#            config.filter "Message", :body, with: :openai, mode: :flag
#          end
#
# ── Why :flag, never :block ───────────────────────────────────────────────────
# This adapter declares `synchronous? == false` (see below), so `moderate` routes
# it through `Moderate::ClassifyJob` in :flag mode and REFUSES it in :block mode.
# You can't synchronously reject a save on a result that's still in flight over the
# network — that's the spine's documented rule ("`:block` requires a synchronous
# adapter"). An async classifier allows the write, classifies in a job, and files a
# `Moderate::Flag` for review.
#
# ── Why `omni-moderation-latest` ──────────────────────────────────────────────
# OpenAI's moderation endpoint is free and the omni model is multimodal (text AND
# image in one call). Crucially, its category set IS the gem's canonical taxonomy
# (`Moderate::Label`) — so the mapping below is 1:1, no lossy translation.
# OpenAI moderation guide:  https://developers.openai.com/api/docs/guides/moderation
# ruby_llm moderation API:  https://github.com/crmne/ruby_llm
# ──────────────────────────────────────────────────────────────────────────────
class OpenAIModerationAdapter
  # The multimodal model. The older text-only "text-moderation-*" models don't
  # accept images and don't return per-category data the same way, so pin omni.
  MODEL = "omni-moderation-latest"

  # The single adapter contract: classify(value) -> Moderate::Result.
  #
  # `value` is whatever the gem hands an adapter for the field — typically a String
  # for a text column. `ruby_llm`'s `RubyLLM.moderate` takes that input plus the
  # model and returns a result exposing `flagged?`, `flagged_categories`, and
  # `category_scores` (see the ruby_llm moderation docs linked in the header).
  def classify(value)
    result = RubyLLM.moderate(value, model: MODEL)

    # `flagged_categories` is the list of canonical slugs that tripped, e.g.
    # ["hate", "hate/threatening", "sexual/minors"]; `category_scores` is a
    # slug => 0.0..1.0 hash. Trust OpenAI's own top-level `flagged?` for the
    # verdict, and surface ONLY the flagged categories as labels (a non-flagged
    # category still carries a near-zero score we don't want in the Flag).
    return Moderate::Result.allowed(source: "external_classifier", raw: result.results) unless result.flagged?

    labels = build_labels(result.flagged_categories, result.category_scores)
    Moderate::Result.new(
      allowed: false,
      labels: labels,
      # "external_classifier" is one of the four values the install migration's
      # moderate_flags_source_check constraint allows; a remote classifier records
      # that. (The human-facing "which backend" detail is the adapter NAME, :openai.)
      source: "external_classifier",
      raw: result.results
    )
  rescue => error
    # FAIL OPEN on EVERYTHING (network error, timeout, auth failure, malformed
    # response, …). A moderation API is best-effort defense-in-depth, not a
    # gatekeeper that should take down user posting when OpenAI has a hiccup — and a
    # :block field is anyway backed by the synchronous :wordlist, never this. The
    # content simply isn't auto-flagged this time; users can still report it. Failing
    # CLOSED (rejecting writes on an upstream outage) would be a far worse outage.
    warn("[moderate] OpenAI moderation call failed (failing open): #{error.class}: #{error.message}")
    Moderate::Result.allowed(source: "external_classifier", raw: { error: error.class.name, message: error.message })
  end

  # Background-only: this does blocking network I/O. Returning false here is exactly
  # what makes the spine route the adapter through Moderate::ClassifyJob in :flag
  # mode and forbid it in :block mode. (The spine probes `synchronous?` directly;
  # an adapter need not inherit from Moderate::Filters::Base — answering this one
  # predicate is enough.)
  def synchronous?
    false
  end

  private

  # One Moderate::Label per FLAGGED canonical slug. OpenAI's slugs are the gem's
  # canonical slugs, so we split "category/subcategory" (e.g. "hate/threatening" ->
  # category :hate, subcategory :threatening; a bare "hate" has no subcategory) and
  # attach the matching 0..1 score. `input: :unknown` because the simple ruby_llm
  # surface doesn't expose OpenAI's per-category `category_applied_input_types`; if
  # you need text-vs-image attribution, read it from `result.results` (the raw
  # payload) and pass `input:` accordingly.
  def build_labels(flagged_categories, scores)
    Array(flagged_categories).map do |slug|
      category, subcategory = slug.to_s.split("/", 2)
      Moderate::Label.new(
        category: category,
        subcategory: subcategory,
        score: scores && scores[slug.to_s],
        flagged: true,
        input: :unknown
      )
    end
  end
end
